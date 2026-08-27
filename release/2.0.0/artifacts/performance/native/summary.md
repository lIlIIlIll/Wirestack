# yjson Native acceleration gate

Qualification: formal 11-round gate.

| Case | Pure median ns | Native median ns | N/P | Native wins | CV P/N | Stable | Gate |
|---|---:|---:|---:|---:|---:|---|---|
| writeNumericArray | 7184755.20 | 7233232.00 | 1.007 | 4/11 | 2.72%/2.87% | yes | pass |
| writeNumericBytes | 2353766.90 | 559331.20 | 0.238 | 11/11 | 1.10%/4.52% | yes | pass |
| readNumericArray | 2746267.39 | 2702645.98 | 0.984 | 6/11 | 3.02%/4.06% | yes | pass |
| readNumericDocument | 2148214.15 | 1211236.31 | 0.564 | 11/11 | 2.42%/4.01% | yes | pass |
| writeEscapedStrings | 1616161.88 | 1611749.05 | 0.997 | 6/11 | 3.41%/3.13% | yes | pass |
| writeEscapedBytes | 1364736.00 | 1366144.00 | 1.001 | 5/11 | 2.17%/4.05% | yes | pass |
| writePlainStrings | 1288000.00 | 1278144.00 | 0.992 | 5/11 | 2.89%/4.05% | yes | pass |
