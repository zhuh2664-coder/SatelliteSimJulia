// ============================================================
// SandboxWorld.cs — 地球 + 卫星点 + ISL 连线
// ============================================================
//
// 启动时 Init(n_sat, isl_pairs)：
//   - 建地球 Sphere（按 Coordinates.EarthRadiusUnits）
//   - 建 N 个卫星 Sphere（小一号）
//   - 建 M 条 ISL LineRenderer（按 isl_pairs 列表）
//
// 每帧 UpdateFrame(positions_flat, isl_avail)：
//   - 更新每颗卫星的 transform.position
//   - 更新每条 ISL 线的两端点 + enabled = isl_avail[i]
//
// 优化点（N<=200 够用，超出需 GPU 实例化）。
// ============================================================

using System.Collections.Generic;
using UnityEngine;

public class SandboxWorld : MonoBehaviour
{
    const float EARTH_SCALE_FACTOR = 1.0f;       // 地球贴图缩放（占位，实际由贴图决定）
    const float SAT_SCALE_UNITS    = 0.20f;      // 卫星小球半径（Unity units）
    const float SAT_COLOR_R        = 1.0f, SAT_COLOR_G = 0.85f, SAT_COLOR_B = 0.3f;

    Transform _earth;
    Transform[] _sats;
    LineRenderer[] _islLines;
    int[] _islA, _islB; // (i,j) 1-based sat indices
    bool _initialised;

    public bool IsInitialised => _initialised;

    /// <summary>构造场景：地球 + N 颗卫星 + M 条 ISL 线。</summary>
    public void Init(int nSat, int[] islA, int[] islB)
    {
        // 地球
        var earthGo = GameObject.CreatePrimitive(PrimitiveType.Sphere);
        earthGo.name = "Earth";
        earthGo.transform.SetParent(transform, false);
        earthGo.transform.localScale = Vector3.one * (Coordinates.EarthRadiusUnits * 2f);
        // 用默认 Standard shader，可挂贴图（用户自己放到 Resources/Textures/earth.jpg）
        var earthMat = new Material(Shader.Find("Standard"));
        earthMat.color = new Color(0.20f, 0.40f, 0.85f);
        var tex = Resources.Load<Texture2D>("Textures/earth");
        if (tex != null)
        {
            earthMat.mainTexture = tex;
            earthMat.color = Color.white;
        }
        earthGo.GetComponent<Renderer>().sharedMaterial = earthMat;
        _earth = earthGo.transform;

        // 卫星
        _sats = new Transform[nSat];
        var satMat = new Material(Shader.Find("Standard"));
        satMat.color = new Color(SAT_COLOR_R, SAT_COLOR_G, SAT_COLOR_B);
        satMat.EnableKeyword("_EMISSION");
        satMat.SetColor("_EmissionColor", new Color(1.0f, 0.9f, 0.4f) * 1.2f);
        for (int i = 0; i < nSat; i++)
        {
            var go = GameObject.CreatePrimitive(PrimitiveType.Sphere);
            go.name = $"Sat{i+1}";
            go.transform.SetParent(transform, false);
            go.transform.localScale = Vector3.one * (SAT_SCALE_UNITS * 2f);
            go.GetComponent<Renderer>().sharedMaterial = satMat;
            // 关闭 collider 节省开销
            Destroy(go.GetComponent<Collider>());
            _sats[i] = go.transform;
        }

        // ISL 连线
        int m = islA.Length;
        _islA = islA; _islB = islB;
        _islLines = new LineRenderer[m];
        var lineMat = new Material(Shader.Find("Sprites/Default"));
        for (int k = 0; k < m; k++)
        {
            var go = new GameObject($"Isl{k}");
            go.transform.SetParent(transform, false);
            var lr = go.AddComponent<LineRenderer>();
            lr.material = lineMat;
            lr.startWidth = 0.05f;
            lr.endWidth = 0.05f;
            lr.positionCount = 2;
            lr.useWorldSpace = true;
            lr.startColor = lr.endColor = new Color(0.3f, 0.9f, 1.0f, 0.6f);
            lr.enabled = false;
            _islLines[k] = lr;
        }

        _initialised = true;
    }

    /// <summary>更新一帧：卫星位置 + ISL 可用性。</summary>
    public void UpdateFrame(double[] positionsFlat, bool[] islAvail)
    {
        if (!_initialised) return;

        // 卫星
        for (int i = 0; i < _sats.Length; i++)
            _sats[i].position = Coordinates.EcefKmToUnity(positionsFlat, i + 1);

        // ISL
        for (int k = 0; k < _islLines.Length; k++)
        {
            bool avail = k < islAvail.Length && islAvail[k];
            if (!avail)
            {
                if (_islLines[k].enabled) _islLines[k].enabled = false;
                continue;
            }
            _islLines[k].enabled = true;
            _islLines[k].SetPosition(0, _sats[_islA[k] - 1].position);
            _islLines[k].SetPosition(1, _sats[_islB[k] - 1].position);
        }
    }
}