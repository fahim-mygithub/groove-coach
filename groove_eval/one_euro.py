"""One Euro adaptive smoothing filter (Casiez, Roussel, Vogel; CHI 2012) for Groove Coach.

An adaptive low-pass filter whose cutoff rises with signal speed: steady during holds, low lag on fast
footwork. Mirrors `ios/GrooveCore/Sources/GrooveCore/OneEuroFilter.swift` with identical defaults and math.

Conventions shared with the Swift port:
- The first sample passes through unchanged (derivative estimate starts at zero).
- A sample whose timestamp is not strictly greater than the previous one is ignored and the last
  filtered value is returned.
"""

from __future__ import annotations

import math
from typing import Dict, List, Optional, Sequence, Tuple

DEFAULT_MIN_CUTOFF = 1.2
DEFAULT_BETA = 3.0
DEFAULT_D_CUTOFF = 1.0


def _alpha(cutoff: float, dt: float) -> float:
    tau = 1.0 / (2.0 * math.pi * cutoff)
    return 1.0 / (1.0 + tau / dt)


class OneEuroFilter:
    """Scalar One Euro filter over timestamped samples."""

    def __init__(
        self,
        min_cutoff: float = DEFAULT_MIN_CUTOFF,
        beta: float = DEFAULT_BETA,
        d_cutoff: float = DEFAULT_D_CUTOFF,
    ) -> None:
        self.min_cutoff = min_cutoff
        self.beta = beta
        self.d_cutoff = d_cutoff
        self.reset()

    def reset(self) -> None:
        self._t: Optional[float] = None
        self._x = 0.0
        self._dx = 0.0

    def filter(self, x: float, t: float) -> float:
        if self._t is None:
            self._t, self._x, self._dx = t, x, 0.0
            return x
        dt = t - self._t
        if not dt > 0.0:
            return self._x
        dx = (x - self._x) / dt
        self._dx += _alpha(self.d_cutoff, dt) * (dx - self._dx)
        cutoff = self.min_cutoff + self.beta * abs(self._dx)
        self._x += _alpha(cutoff, dt) * (x - self._x)
        self._t = t
        return self._x


class OneEuroFilter3D:
    """Three independent scalar filters over (x, y, z) sharing one timestamp."""

    def __init__(
        self,
        min_cutoff: float = DEFAULT_MIN_CUTOFF,
        beta: float = DEFAULT_BETA,
        d_cutoff: float = DEFAULT_D_CUTOFF,
    ) -> None:
        self._axes = [OneEuroFilter(min_cutoff, beta, d_cutoff) for _ in range(3)]

    def reset(self) -> None:
        for f in self._axes:
            f.reset()

    def filter(self, point: Sequence[float], t: float) -> List[float]:
        return [f.filter(point[i] if i < len(point) else 0.0, t) for i, f in enumerate(self._axes)]


class OneEuroLandmarkBank:
    """Dictionary of joint name -> 3D filter, fed with timestamped pose frames."""

    def __init__(
        self,
        min_cutoff: float = DEFAULT_MIN_CUTOFF,
        beta: float = DEFAULT_BETA,
        d_cutoff: float = DEFAULT_D_CUTOFF,
    ) -> None:
        self._params: Tuple[float, float, float] = (min_cutoff, beta, d_cutoff)
        self._filters: Dict[str, OneEuroFilter3D] = {}

    def reset(self) -> None:
        self._filters.clear()

    def filter(self, joints: Dict[str, Sequence[float]], t: float) -> Dict[str, List[float]]:
        out: Dict[str, List[float]] = {}
        for name, point in joints.items():
            f = self._filters.get(name)
            if f is None:
                f = self._filters[name] = OneEuroFilter3D(*self._params)
            out[name] = f.filter(point, t)
        return out
