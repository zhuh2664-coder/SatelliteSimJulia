# test/runtests.jl — Pkg.test() 默认入口
#
# 旧版单体测试文件已整体迁移到 runtests_current.jl。
# 此文件仅作为转发入口，保持与 Julia Pkg.test() 的约定兼容。

include(joinpath(@__DIR__, "runtests_current.jl"))
