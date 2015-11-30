%%%-------------------------------------------------------------------
%%% @doc Serialization/deserializtion for neo4j's bolt binary protocol
%%%
%%%      Documentation:
%%%        - https://github.com/nigelsmall/bolt-howto/blob/master/packstream.py
%%%        - https://github.com/nigelsmall/bolt-howto
%%%
%%% @author Dmitrii Dimandt
%%% @copyright (C) 2015 Dmitrii Dimandt
%%%-------------------------------------------------------------------
-module(neo4j_bolt).
-author("dmitriid").

%%_* Exports ===================================================================
-export([ serialize/1
        , deserialize/1
        ]).

%%_* API =======================================================================

%%  Null
%%  ----
%%  Null is always encoded using the single marker byte 0xC0.
%%      C0  -- Null
serialize(null) ->
  <<16#C0/integer>>;

%%  Boolean
%%  -------
%%  Boolean values are encoded within a single marker byte, using 0xC3 to denote
%%  true and 0xC2 to denote false.
%%      C3  -- True
%%      C2  -- False
serialize(true)  -> <<16#C3/integer>>;
serialize(false) -> <<16#C2/integer>>;

%%  Floating Point Numbers
%%  ----------------------
%%  These are double-precision floating points for approximations of any number,
%%  notably for representing fractions and decimal numbers. Floats are encoded as a
%%  single 0xC1 marker byte followed by 8 bytes, formatted according to the IEEE
%%  754 floating-point "double format" bit layout.
%%  - Bit 63 (the bit that is selected by the mask `0x8000000000000000`) represents
%%    the sign of the number.
%%  - Bits 62-52 (the bits that are selected by the mask `0x7ff0000000000000`)
%%    represent the exponent.
%%  - Bits 51-0 (the bits that are selected by the mask `0x000fffffffffffff`)
%%    represent the significand (sometimes called the mantissa) of the number.
%%      C1 3F F1 99 99 99 99 99 9A  -- Float(+1.1)
%%      C1 BF F1 99 99 99 99 99 9A  -- Float(-1.1)
serialize(Float) when is_float(Float) ->
  <<16#C1/integer, Float/float>>;

%%  Integers
%%  --------
%%  Integer values occupy either 1, 2, 3, 5 or 9 bytes depending on magnitude and
%%  are stored as big-endian signed values. Several markers are designated
%%  specifically as TINY_INT values and can therefore be used to pass a small
%%  number in a single byte. These markers can be identified by a zero high-order
%%  bit or by a high-order nibble containing only ones.
%%  The available encodings are illustrated below and each shows a valid
%%  representation for the decimal value 42:
%%      2A                          -- TINY_INT
%%      C8 2A                       -- INT_8
%%      C9 00 2A                    -- INT_16
%%      CA 00 00 00 2A              -- INT_32
%%      CB 00 00 00 00 00 00 00 2A  -- INT_64
%%  Note that while encoding small numbers in wider formats is supported, it is
%%  generally recommended to use the most compact representation possible. The
%%  following table shows the optimal representation for every possible integer:
%%     Range Minimum             |  Range Maximum             | Representation
%%   ============================|============================|================
%%    -9 223 372 036 854 775 808 |             -2 147 483 649 | INT_64
%%                -2 147 483 648 |                    -32 769 | INT_32
%%                       -32 768 |                       -129 | INT_16
%%                          -128 |                        -17 | INT_8
%%                           -16 |                       +127 | TINY_INT
%%                          +128 |                    +32 767 | INT_16
%%                       +32 768 |             +2 147 483 647 | INT_32
%%                +2 147 483 648 | +9 223 372 036 854 775 807 | INT_64
serialize(Int) when is_integer(Int) ->
  if
    %% TINY_INT
    Int >= -16 andalso Int =< 127 ->
      <<Int:1/big-signed-integer-unit:8>>;
    %% INT_8
    Int >= -128 andalso Int =< 17 ->
      <<16#C8/integer
      , Int:1/big-signed-integer-unit:8>>;
    %% INT_16
    Int >= -32768 andalso Int =< -129
    orelse
    Int >= 128 andalso Int =< 32767 ->
      <<16#C9/integer
      , Int:2/big-signed-integer-unit:8>>;
    %% INT_32
    Int >= -2147483648 andalso Int =< -32769
    orelse
    Int >= 32768 andalso Int =< 2147483647 ->
      <<16#CA/integer
      , Int:4/big-signed-integer-unit:8>>;
    %% INT_64
    Int >= -9223372036854775808 andalso Int =< -2147483649
    orelse
    Int >= 2147483648 andalso Int =< 9223372036854775807 ->
      <<16#CB/integer
      , Int:8/big-signed-integer-unit:8>>;
    true ->
      error({integer, too_large})
  end;

%%  Text
%%  ----
%%  Text data is represented as UTF-8 encoded binary data. Note that sizes used
%%  for text are the byte counts of the UTF-8 encoded data, not the character count
%%  of the original text.
%%    Marker | Size                                        | Maximum size
%%   ========|=============================================|=====================
%%    80..8F | contained within low-order nibble of marker | 15 bytes
%%    D0     | 8-bit big-endian unsigned integer           | 255 bytes
%%    D1     | 16-bit big-endian unsigned integer          | 65 535 bytes
%%    D2     | 32-bit big-endian unsigned integer          | 4 294 967 295 bytes
%%  For encoded text containing fewer than 16 bytes, including empty strings,
%%  the marker byte should contain the high-order nibble `1000` followed by a
%%  low-order nibble containing the size. The encoded data then immediately
%%  follows the marker.
%%  For encoded text containing 16 bytes or more, the marker 0xD0, 0xD1 or 0xD2
%%  should be used, depending on scale. This marker is followed by the size and
%%  the UTF-8 encoded data. Examples follow below:
%%      80  -- ""
%%      81 61  -- "a"
%%      D0 1A 61 62  63 64 65 66  67 68 69 6A  6B 6C 6D 6E
%%      6F 70 71 72  73 74 75 76  77 78 79 7A  -- "abcdefghijklmnopqrstuvwxyz"
%%      D0 18 45 6E  20 C3 A5 20  66 6C C3 B6  74 20 C3 B6
%%      76 65 72 20  C3 A4 6E 67  65 6E  -- "En å flöt över ängen"
serialize(Text) when is_binary(Text), byte_size(Text) =< 15 ->
  SizeMarker = 16#80 + byte_size(Text),
  <<SizeMarker/integer, Text/binary>>;
serialize(Text) when is_binary(Text) ->
  ByteSize = byte_size(Text),
  {Marker, Size} =
    if
      ByteSize =< 255 ->
        { <<16#D0/integer>>
        , <<ByteSize:1/big-unsigned-integer-unit:8>>};
      ByteSize =< 65535 ->
        { <<16#D1/integer>>
        , <<ByteSize:2/big-unsigned-integer-unit:8>>};
      ByteSize =< 4294967295 ->
        { <<16#D2/integer>>
        , <<ByteSize:4/big-unsigned-integer-unit:8>>};
      true -> error({text, size_too_big})
    end,
  <<Marker/binary, Size/binary, Text/binary>>;

serialize(Text) when is_binary(Text) ->
  error(not_implemented);
serialize(_) ->
  error(not_implemented).


%%  Null
%%  ----
%%  Null is always encoded using the single marker byte 0xC0.
%%      C0  -- Null
deserialize(<<16#C0/integer>>) ->
  null;
%%  Boolean
%%  -------
%%  Boolean values are encoded within a single marker byte, using 0xC3 to denote
%%  true and 0xC2 to denote false.
%%      C3  -- True
%%      C2  -- False
deserialize(<<16#C3/integer>>)  -> true;
deserialize(<<16#C2/integer>>) -> false;
%%  Floating Point Numbers
%%  ----------------------
%%  These are double-precision floating points for approximations of any number,
%%  notably for representing fractions and decimal numbers. Floats are encoded as a
%%  single 0xC1 marker byte followed by 8 bytes, formatted according to the IEEE
%%  754 floating-point "double format" bit layout.
%%  - Bit 63 (the bit that is selected by the mask `0x8000000000000000`) represents
%%    the sign of the number.
%%  - Bits 62-52 (the bits that are selected by the mask `0x7ff0000000000000`)
%%    represent the exponent.
%%  - Bits 51-0 (the bits that are selected by the mask `0x000fffffffffffff`)
%%    represent the significand (sometimes called the mantissa) of the number.
%%      C1 3F F1 99 99 99 99 99 9A  -- Float(+1.1)
%%      C1 BF F1 99 99 99 99 99 9A  -- Float(-1.1)
deserialize(<<16#C1/integer, Float/float>>) ->
  Float;
%%  Integers
%%  --------
%%  Integer values occupy either 1, 2, 3, 5 or 9 bytes depending on magnitude and
%%  are stored as big-endian signed values. Several markers are designated
%%  specifically as TINY_INT values and can therefore be used to pass a small
%%  number in a single byte. These markers can be identified by a zero high-order
%%  bit or by a high-order nibble containing only ones.
%%  The available encodings are illustrated below and each shows a valid
%%  representation for the decimal value 42:
%%      2A                          -- TINY_INT
%%      C8 2A                       -- INT_8
%%      C9 00 2A                    -- INT_16
%%      CA 00 00 00 2A              -- INT_32
%%      CB 00 00 00 00 00 00 00 2A  -- INT_64
%%  Note that while encoding small numbers in wider formats is supported, it is
%%  generally recommended to use the most compact representation possible. The
%%  following table shows the optimal representation for every possible integer:
%%     Range Minimum             |  Range Maximum             | Representation
%%   ============================|============================|================
%%    -9 223 372 036 854 775 808 |             -2 147 483 649 | INT_64
%%                -2 147 483 648 |                    -32 769 | INT_32
%%                       -32 768 |                       -129 | INT_16
%%                          -128 |                        -17 | INT_8
%%                           -16 |                       +127 | TINY_INT
%%                          +128 |                    +32 767 | INT_16
%%                       +32 768 |             +2 147 483 647 | INT_32
%%                +2 147 483 648 | +9 223 372 036 854 775 807 | INT_64
%% TINY_INT
%% The guerd is there because <<16#80>> is <<>> (see Text deserialization below)
deserialize(<<Int:1/big-signed-integer-unit:8>>) when Int >= -16, Int =< 127 ->
  Int;
%% INT_8
deserialize(<<16#C8/integer
            , Int:1/big-signed-integer-unit:8>>) ->
  Int;
%% INT_16
deserialize(<<16#C9/integer
            , Int:2/big-signed-integer-unit:8>>)->
  Int;
%% INT_32
deserialize(<<16#CA/integer
            , Int:4/big-signed-integer-unit:8>>) ->
  Int;
%% INT_64
deserialize(<<16#CB/integer
            , Int:8/big-signed-integer-unit:8>>) ->
  Int;
%%  Text
%%  ----
%%  Text data is represented as UTF-8 encoded binary data. Note that sizes used
%%  for text are the byte counts of the UTF-8 encoded data, not the character count
%%  of the original text.
%%    Marker | Size                                        | Maximum size
%%   ========|=============================================|=====================
%%    80..8F | contained within low-order nibble of marker | 15 bytes
%%    D0     | 8-bit big-endian unsigned integer           | 255 bytes
%%    D1     | 16-bit big-endian unsigned integer          | 65 535 bytes
%%    D2     | 32-bit big-endian unsigned integer          | 4 294 967 295 bytes
%%  For encoded text containing fewer than 16 bytes, including empty strings,
%%  the marker byte should contain the high-order nibble `1000` followed by a
%%  low-order nibble containing the size. The encoded data then immediately
%%  follows the marker.
%%  For encoded text containing 16 bytes or more, the marker 0xD0, 0xD1 or 0xD2
%%  should be used, depending on scale. This marker is followed by the size and
%%  the UTF-8 encoded data. Examples follow below:
%%      80  -- ""
%%      81 61  -- "a"
%%      D0 1A 61 62  63 64 65 66  67 68 69 6A  6B 6C 6D 6E
%%      6F 70 71 72  73 74 75 76  77 78 79 7A  -- "abcdefghijklmnopqrstuvwxyz"
%%      D0 18 45 6E  20 C3 A5 20  66 6C C3 B6  74 20 C3 B6
%%      76 65 72 20  C3 A4 6E 67  65 6E  -- "En å flöt över ängen"
deserialize(<<16#80>>) ->
  <<>>;
deserialize(<<Marker/integer, B/binary>>) when Marker > 16#80
                                             , Marker =< 16#8F ->
  Size = Marker - 16#80,
  <<Text:Size/binary-unit:8, _/binary>> = B,
  Text;
deserialize(<<16#D0/integer
            , ByteSize:1/big-unsigned-integer-unit:8
            , Text:ByteSize/binary-unit:8>>
           ) ->
  Text;
deserialize(<<16#D1/integer
            , ByteSize:2/big-unsigned-integer-unit:8
            , Text:ByteSize/binary-unit:8>>
           ) ->
  Text;
deserialize(<<16#D2/integer
            , ByteSize:4/big-unsigned-integer-unit:8
            , Text:ByteSize/binary-unit:8>>
           ) ->
  Text;
%%  ByteSize = byte_size(Text),
%%  {Marker, Size} =
%%    if
%%      ByteSize =< 255 ->
%%        { <<16#D0/integer>>
%%        , <<ByteSize:1/big-unsigned-integer-unit:8>>};
%%      ByteSize =< 65535 ->
%%        { <<16#D1/integer>>
%%        , <<ByteSize:2/big-unsigned-integer-unit:8>>};
%%      ByteSize =< 4294967295 ->
%%        { <<16#D2/integer>>
%%        , <<ByteSize:4/big-unsigned-integer-unit:8>>};
%%      true -> error({text, size_too_big})
%%    end,
%%  <<Marker/binary, Size/binary, Text/binary>>;
deserialize(_) ->
  error(not_implemented).
