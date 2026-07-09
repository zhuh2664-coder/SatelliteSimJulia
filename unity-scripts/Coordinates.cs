// ============================================================
// Coordinates.cs — 坐标转换工具（ECEF km → Unity 世界坐标）
// ============================================================
//
// ECEF（地心地固坐标系）：X → 赤道面 0 经度，Y → 90°E，Z → 北极
// Unity 左手坐标系：   X → 右，Y → 上，Z → 前
//
// 沙盒场景用近似旋转：ECEF.Z → Unity.Y，ECEF.Y → Unity.(-Z)
//
// 缩放：默认 1 unit = 100 km → 地球半径 63.78 units。
// ============================================================

using UnityEngine;

public static class Coordinates
{
    /// <summary>1 unit = 100 km。可在 Inspector 调。</summary>
    public static float ScaleKmPerUnit = 100f;

    /// <summary>
    /// 把 ECEF km 单帧展平数组中的某一颗卫星 (x,y,z) 转换为 Unity 世界坐标。
    /// </summary>
    /// <param name="flat">positions_flat = [x1,y1,z1, x2,y2,z2, ...]</param>
    /// <param name="satIndex">1-based 卫星索引</param>
    public static Vector3 EcefKmToUnity(double[] flat, int satIndex)
    {
        int i = (satIndex - 1) * 3;
        double xKm = flat[i];
        double yKm = flat[i + 1];
        double zKm = flat[i + 2];
        float s = ScaleKmPerUnit;
        return new Vector3(
            (float)(xKm / s),
            (float)(zKm / s),   // 北极 → Unity Y（上）
            (float)(-yKm / s)   // 90°E → Unity -Z（前）
        );
    }

    /// <summary>地球半径（单位），用于生成 Sphere 模型。</summary>
    public static float EarthRadiusUnits => 6378.137f / ScaleKmPerUnit;
}