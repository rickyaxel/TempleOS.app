"""Exact rendering of logical pixel art to any raster size.

Each logical pixel is an ideal square of side `cell` output pixels placed at `origin`.
An output pixel receives the area-weighted average of the squares it overlaps (separable
box integration, premultiplied alpha). Consequences:

  * integer cell size + integer origin -> every output pixel lies inside one logical
    pixel: hard edges, exact palette colors, no interpolation at all (the iOS master);
  * fractional cell size (Android densities) -> pixels on a square's border get the true
    coverage mix and nothing else: no blur kernel wider than one output pixel, no ringing,
    no halos, no detail dropped the way nearest-neighbor downscaling drops thin lines.
"""
import numpy as np


def _weights(n_out, n_cells, cell, origin):
    """W[u, i] = overlap of output pixel u = [u, u+1) with cell i = [origin + i*cell, origin + (i+1)*cell)."""
    u0 = np.arange(n_out, dtype=np.float64)[:, None]
    c0 = origin + np.arange(n_cells, dtype=np.float64)[None, :] * cell
    return np.clip(np.minimum(u0 + 1, c0 + cell) - np.maximum(u0, c0), 0, None)


def render_rgba(labels, palette_rgb, size, cell, origin, transparent=(0,), canvas=None):
    """Render to (size, size, 4) uint8.

    transparent: palette indices that render as alpha 0 (the background layer shows through).
    canvas: RGB color under everything (opaque result), or None for a transparent canvas.
    """
    H, W = labels.shape
    pal = np.asarray(palette_rgb, np.float64)
    rgba = np.concatenate([pal, np.full((len(pal), 1), 255.0)], 1)
    for k in transparent:
        rgba[k] = 0.0
    cells = rgba[labels]                                       # (H, W, 4), straight alpha
    cells[..., :3] *= cells[..., 3:4] / 255.0                  # premultiply
    Wx = _weights(size, W, cell, origin[0])
    Wy = _weights(size, H, cell, origin[1])
    rows = (Wy @ cells.reshape(H, W * 4)).reshape(size, W, 4)  # integrate over rows, then columns
    out = np.matmul(rows.transpose(0, 2, 1), Wx.T).transpose(0, 2, 1)   # premultiplied, coverage-weighted
    if canvas is not None:
        a = out[..., 3:4] / 255.0
        out[..., :3] = out[..., :3] + (1 - a) * np.asarray(canvas, np.float64)
        out[..., 3] = 255.0
        return np.clip(np.rint(out), 0, 255).astype(np.uint8)
    a = out[..., 3:4]
    rgb = np.where(a > 0, out[..., :3] * 255.0 / np.maximum(a, 1e-9), 0)
    res = np.concatenate([rgb, a], -1)
    return np.clip(np.rint(res), 0, 255).astype(np.uint8)


def render_alpha(mask, size, cell, origin):
    """Coverage of a boolean logical mask -> (size, size) uint8 alpha."""
    Wx = _weights(size, mask.shape[1], cell, origin[0])
    Wy = _weights(size, mask.shape[0], cell, origin[1])
    return np.clip(np.rint(Wy @ mask.astype(np.float64) @ Wx.T * 255.0), 0, 255).astype(np.uint8)
