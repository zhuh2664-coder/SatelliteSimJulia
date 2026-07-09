module SatelliteSimVizGLMakieExt

# 当用户同时加载 SatelliteSimJulia 和 SatelliteSimViz 时触发
# 将 Viz 的导出重新暴露到 SatelliteSimJulia 命名空间

using SatelliteSimJulia
using SatelliteSimViz

# Re-export Viz symbols so using SatelliteSimJulia gets them too
using Reexport
@reexport using SatelliteSimViz

end
