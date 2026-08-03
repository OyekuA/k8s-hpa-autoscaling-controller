import os
import math
from fastapi import FastAPI

app = FastAPI()

_raw = os.environ.get("PRIME_LIMIT", "100000")
try:
    PRIME_LIMIT = int(_raw)
except ValueError:
    raise ValueError(
        f"PRIME_LIMIT must be a valid integer, got {_raw!r}"
    ) from None
if PRIME_LIMIT < 2:
    raise ValueError(
        f"PRIME_LIMIT must be an integer >= 2, got {_raw!r}"
    ) from None


def is_prime(n: int) -> bool:
    if n < 2:
        return False
    if n == 2:
        return True
    if n % 2 == 0:
        return False
    limit = int(math.isqrt(n))
    for i in range(3, limit + 1, 2):
        if n % i == 0:
            return False
    return True


def count_primes(limit: int) -> int:
    count = 0
    for n in range(2, limit + 1):
        if is_prime(n):
            count += 1
    return count


@app.get("/compute-heavy")
def compute_heavy():
    primes_found = count_primes(PRIME_LIMIT)
    return {"status": "completed", "primes_found": primes_found}
