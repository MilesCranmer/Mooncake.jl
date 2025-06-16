# test/mwe.jl
using Pkg
Pkg.activate(@__DIR__)
Pkg.develop(path=".")
Pkg.develop(path="./ext/dynamic_expressions")
Pkg.instantiate()

using Mooncake
using Mooncake: Mooncake
using DynamicExpressions
using StableRNGs: StableRNG
using DifferentiationInterface: AutoMooncake, gradient, prepare_gradient
using Test

@testset "MWE" begin
    operators = OperatorEnum(1 => (cos, ), 2 => (+, ))
    x1, x2 = (Expression(Node{Float64}(; feature=i); operators) for i in 1:2)
    f = x1 + x2
    X = randn(StableRNG(0), 2, 10)
    eval_sum = let f = f
        X -> sum(f(X))
    end
    backend = AutoMooncake(; config=nothing)

    # Add debug prints to inspect types
    try
        prep = prepare_gradient(eval_sum, backend, X)
        dX = gradient(eval_sum, prep, backend, X)
        @test dX ≈ ones(2, 10)
    catch e
        if e isa TypeError
            println("Caught TypeError as expected.")
            println("Error message: ", e.msg)
            println("Function: ", e.func)
            println("Context: ", e.context)
            println("Expected type: ", e.expected)
            println("Got type: ", e.got)
        end
        rethrow(e)
    end
end