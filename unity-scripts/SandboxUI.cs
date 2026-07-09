// ============================================================
// SandboxUI.cs — uGUI 面板（代码生成，无 Prefab 依赖）
// ============================================================
//
// 包含：
//   - 星座下拉框（TMP_Dropdown）
//   - 开始/停止按钮
//   - 速度滑块（0.5× / 1× / 2× / 5×）
//   - 指标 HUD（卫星数 / 当前帧 / ISL 可用数）
//
// 文本用 UnityEngine.UI.Text，避免 TextMeshPro 字体依赖（首期）。要 TMP 自行替换。
// ============================================================

using System;
using UnityEngine;
using UnityEngine.UI;

public class SandboxUI : MonoBehaviour
{
    public Dropdown ConstellationDropdown;
    public Button StartStopButton;
    public Slider SpeedSlider;
    public Text StatusText;
    public Text HudText;

    string[] _names = Array.Empty<string>();
    bool _running;

    public event Action<string> OnStartClicked;
    public event Action OnStopClicked;
    public event Action<float> OnSpeedChanged;

    public void SetConstellationList(string[] names)
    {
        _names = names;
        ConstellationDropdown.ClearOptions();
        var opts = new System.Collections.Generic.List<string>(names);
        ConstellationDropdown.AddOptions(opts);
    }

    public string SelectedConstellation
        => ConstellationDropdown.value < _names.Length
           ? _names[ConstellationDropdown.value] : "";

    public void SetRunning(bool running)
    {
        _running = running;
        var label = StartStopButton.GetComponentInChildren<Text>();
        if (label != null) label.text = running ? "Stop" : "Start";
        StatusText.text = running ? "Streaming…" : "Idle";
    }

    public void SetHud(int nSat, int frameIdx, int nTotal, int islAvail, int islTotal)
    {
        HudText.text =
            $"sats: {nSat}    frame: {frameIdx}/{nTotal}    ISL: {islAvail}/{islTotal}";
    }

    public void SetStatus(string s) => StatusText.text = s;

    void Awake()
    {
        BuildUI();
        StartStopButton.onClick.AddListener(() =>
        {
            if (_running) OnStopClicked?.Invoke();
            else OnStartClicked?.Invoke(SelectedConstellation);
            SetRunning(!_running);
        });
        SpeedSlider.onValueChanged.AddListener(v => OnSpeedChanged?.Invoke(v));
    }

    // ── 代码生成 UI（无 Prefab 依赖） ──────────────────────

    void BuildUI()
    {
        var canvasGo = new GameObject("Canvas");
        canvasGo.transform.SetParent(transform, false);
        var canvas = canvasGo.AddComponent<Canvas>();
        canvas.renderMode = RenderMode.ScreenSpaceOverlay;
        canvasGo.AddComponent<CanvasScaler>().uiScaleMode = CanvasScaler.ScaleMode.ScaleWithScreenSize;
        canvasGo.AddComponent<GraphicRaycaster>();

        // 背景面板（顶部）
        var panel = MakeUI("TopPanel", canvasGo.transform);
        var prt = panel.GetComponent<RectTransform>();
        prt.anchorMin = new Vector2(0, 1); prt.anchorMax = new Vector2(1, 1);
        prt.pivot = new Vector2(0.5f, 1);
        prt.sizeDelta = new Vector2(0, 100);
        prt.anchoredPosition = Vector2.zero;
        var pimg = panel.AddComponent<Image>();
        pimg.color = new Color(0, 0, 0, 0.55f);

        // 水平布局
        var hlg = panel.AddComponent<HorizontalLayoutGroup>();
        hlg.padding = new RectOffset(20, 20, 15, 15);
        hlg.spacing = 12;
        hlg.childAlignment = TextAnchor.MiddleLeft;
        hlg.childControlHeight = true; hlg.childControlWidth = false;
        hlg.childForceExpandHeight = false; hlg.childForceExpandWidth = false;

        // 星座下拉框
        ConstellationDropdown = MakeDropdown(panel.transform, "Constellation", 200);

        // 开始/停止
        StartStopButton = MakeButton(panel.transform, "Start", 90);
        SetRunning(false);

        // 速度滑块（用按钮替代以简单实现）
        SpeedSlider = MakeSlider(panel.transform, 200);

        // 状态文本（最右拉伸）
        StatusText = MakeText(panel.transform, "Idle", 250);
        StatusText.alignment = TextAnchor.MiddleRight;

        // 底部 HUD
        HudText = MakeText(canvasGo.transform, "sats: -", 24);
        var hrt = HudText.rectTransform;
        hrt.anchorMin = new Vector2(0, 0); hrt.anchorMax = new Vector2(1, 0);
        hrt.pivot = new Vector2(0.5f, 0);
        hrt.sizeDelta = new Vector2(0, 30);
        hrt.anchoredPosition = new Vector2(0, 10);
        HudText.alignment = TextAnchor.MiddleCenter;
    }

    static GameObject MakeUI(string name, Transform parent)
    {
        var go = new GameObject(name);
        go.transform.SetParent(parent, false);
        go.AddComponent<RectTransform>();
        return go;
    }

    static Text MakeText(Transform parent, string content, float width)
    {
        var go = MakeUI("Text", parent);
        go.AddComponent<LayoutElement>().preferredWidth = width;
        var t = go.AddComponent<Text>();
        t.text = content;
        t.color = Color.white;
        t.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
        t.fontSize = 16;
        t.alignment = TextAnchor.MiddleLeft;
        return t;
    }

    static Button MakeButton(Transform parent, string label, float width)
    {
        var go = MakeUI("Btn", parent);
        go.AddComponent<LayoutElement>().preferredWidth = width;
        var img = go.AddComponent<Image>();
        img.color = new Color(0.25f, 0.55f, 0.85f);
        var btn = go.AddComponent<Button>();
        var lbl = MakeText(go.transform, label, 0);
        lbl.alignment = TextAnchor.MiddleCenter;
        lbl.rectTransform.anchorMin = Vector2.zero;
        lbl.rectTransform.anchorMax = Vector2.one;
        lbl.rectTransform.sizeDelta = Vector2.zero;
        lbl.rectTransform.anchoredPosition = Vector2.zero;
        return btn;
    }

    static Dropdown MakeDropdown(Transform parent, string label, float width)
    {
        var go = MakeUI("Dropdown", parent);
        go.AddComponent<LayoutElement>().preferredWidth = width;
        var img = go.AddComponent<Image>();
        img.color = new Color(0.15f, 0.15f, 0.18f);
        var dd = go.AddComponent<Dropdown>();
        // caption（label）
        var capGo = MakeUI("Caption", go.transform);
        var capRt = capGo.GetComponent<RectTransform>();
        capRt.anchorMin = Vector2.zero; capRt.anchorMax = Vector2.one;
        capRt.sizeDelta = new Vector2(-20, 0);
        var cap = capGo.AddComponent<Text>();
        cap.text = label; cap.color = Color.white;
        cap.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
        cap.fontSize = 16;
        cap.alignment = TextAnchor.MiddleLeft;
        dd.captionText = cap;
        return dd;
    }

    static Slider MakeSlider(Transform parent, float width)
    {
        var go = MakeUI("Speed", parent);
        go.AddComponent<LayoutElement>().preferredWidth = width;
        var slider = go.AddComponent<Slider>();
        slider.minValue = 0.25f; slider.maxValue = 5f; slider.value = 1f;
        // 背景
        var bg = MakeUI("Background", go.transform);
        bg.GetComponent<RectTransform>().anchorMin = new Vector2(0, 0.5f);
        bg.GetComponent<RectTransform>().anchorMax = new Vector2(1, 0.5f);
        bg.GetComponent<RectTransform>().sizeDelta = new Vector2(0, 4);
        bg.AddComponent<Image>().color = new Color(0.3f, 0.3f, 0.35f);
        // 填充区
        var fillArea = MakeUI("Fill Area", go.transform);
        fillArea.GetComponent<RectTransform>().anchorMin = new Vector2(0, 0.5f);
        fillArea.GetComponent<RectTransform>().anchorMax = new Vector2(1, 0.5f);
        fillArea.GetComponent<RectTransform>().offsetMin = new Vector2(5, 0);
        fillArea.GetComponent<RectTransform>().offsetMax = new Vector2(-5, 0);
        var fill = MakeUI("Fill", fillArea.transform);
        fill.GetComponent<RectTransform>().anchorMin = Vector2.zero;
        fill.GetComponent<RectTransform>().anchorMax = Vector2.one;
        fill.GetComponent<RectTransform>().sizeDelta = new Vector2(10, 0);
        fill.AddComponent<Image>().color = new Color(0.4f, 0.75f, 1f);
        // Handle
        var handleArea = MakeUI("Handle Slide Area", go.transform);
        handleArea.GetComponent<RectTransform>().anchorMin = new Vector2(0, 0);
        handleArea.GetComponent<RectTransform>().anchorMax = new Vector2(1, 1);
        var handle = MakeUI("Handle", handleArea.transform);
        handle.GetComponent<RectTransform>().sizeDelta = new Vector2(20, 0);
        handle.AddComponent<Image>().color = Color.white;
        slider.fillRect = fill.GetComponent<RectTransform>();
        slider.handleRect = handle.GetComponent<RectTransform>();
        slider.targetGraphic = handle.GetComponent<Image>();
        return slider;
    }
}