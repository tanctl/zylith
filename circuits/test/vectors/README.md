circom test vectors

format
- each vector file lives under circuits/test/vectors/<suite>/<name>.json
- schema:
  {
    "input": { ... },
    "expect": {
      "outputs": { "signal_name": "value_as_decimal_or_hex" }
    },
    "should_fail": false
  }

notes
- values must be strings or numbers, prefer strings for u256.
- for fail cases, set should_fail to true and provide the failing input.
- vector generation should use ekubo core outputs and the same math as circuits.
- if a vector file is missing, the corresponding test is skipped (set ZYLITH_REQUIRE_VECTORS=1 to fail instead).
