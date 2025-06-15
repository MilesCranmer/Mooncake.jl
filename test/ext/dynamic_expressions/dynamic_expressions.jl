using Pkg
Pkg.activate(@__DIR__)
Pkg.develop(; path=joinpath(@__DIR__, "..", "..", ".."))

using Mooncake
using Mooncake: Mooncake
using Mooncake.TestUtils: test_rule
using DynamicExpressions, Random
using DifferentiationInterface: AutoMooncake, gradient, prepare_gradient
using StableRNGs, Test
using Statistics: mean

@testset "Basic usage checks" begin
    # Build up expression
    operators = OperatorEnum(1 => (cos, sin), 2 => (+, -, *, /))
    x1, x2 = (
        Expression(Node{Float64}(; feature=i); operators) for i in 1:2
    )

    f = x1 + cos(x2 - 0.2) + 0.5
    X = randn(MersenneTwister(0), 3, 100)

    eval_sum = let f = f
        X -> sum(f(X))
    end
    backend = AutoMooncake(; config=nothing)
    prep = prepare_gradient(eval_sum, backend, X)
    dX = gradient(eval_sum, prep, backend, X)

    # analytic derivative: df/dx1 = 1, df/dx2 = -sin(x2 - 0.2), df/dx3 = 0
    dX_ref = zeros(size(X))
    dX_ref[1, :] .= 1
    dX_ref[2, :] .= -sin.(X[2, :] .- 0.2)
    # third row already zero
    @test isapprox(dX, dX_ref; rtol=1e-10, atol=0)
end

@testset "Gradient of tree parameters" begin
    operators = OperatorEnum(1 => (cos, sin), 2 => (+, -, *, /))
    x1 = Expression(Node{Float64}(; feature=1); operators)

    #  simple closed‑form ground truth: ∂/∂c sum(x1 + c) = N
    N = 100
    Xc = randn(MersenneTwister(0), 3, N)
    expr = x1 + 0.0      # constant in the tree

    eval_sum_c = let X = Xc
        f -> sum(f(X))
    end

    backend = AutoMooncake(; config=nothing)
    prep = prepare_gradient(eval_sum_c, backend, expr)
    dexpr = gradient(eval_sum_c, prep, backend, expr)

    const_tangent = dexpr.fields.tree.children[2].val
    @test const_tangent ≈ N
end

# Standard TestUtils tests
@testset "TestUtils systematic tests" begin
    # Set up common test data
    operators = OperatorEnum(1 => (cos, sin, exp, log), 2 => (+, -, *, /))
    
    # Helper function to create test expressions
    function create_test_expressions()
        x1 = Expression(Node{Float64}(; feature=1); operators)
        x2 = Expression(Node{Float64}(; feature=2); operators)
        
        # Various expression types
        expressions = [
            x1,  # Simple variable
            x1 + 1.0,  # Variable plus constant
            x1 * x2,  # Two variables
            cos(x1),  # Unary function
            x1 + cos(x2),  # Mixed operations
            x1 * x2 + sin(x1 - 0.5),  # Complex expression
        ]
        
        return expressions
    end
    
    # Create test data
    expressions = create_test_expressions()
    test_matrices = [
        randn(StableRNG(1), 3, 5),
        randn(StableRNG(2), 2, 10),
        randn(StableRNG(3), 4, 8),
    ]
    
    # Test cases for expression evaluation
    test_cases = []
    
    # Test basic expression evaluation
    for (i, expr) in enumerate(expressions)
        for (j, X) in enumerate(test_matrices)
            # Test direct evaluation
            push!(test_cases, (
                false,  # interface_only
                :none,  # perf_flag
                false,  # is_primitive
                expr,   # function
                X       # arguments
            ))
            
            # Test sum of evaluation (common pattern)
            eval_sum = let expr = expr
                X -> sum(expr(X))
            end
            push!(test_cases, (
                false,  # interface_only
                :none,  # perf_flag
                false,  # is_primitive
                eval_sum,  # function
                X          # arguments
            ))
        end
    end
    
    # Test additional DynamicExpressions operations
    x1 = Expression(Node{Float64}(; feature=1); operators)
    x2 = Expression(Node{Float64}(; feature=2); operators)
    test_X = randn(StableRNG(42), 3, 20)
    
    # Test expression arithmetic operations
    additional_test_cases = [
        # Test expression evaluation with different operations
        (false, :none, false, X -> (x1 + x2)(X), test_X),
        (false, :none, false, X -> (x1 - x2)(X), test_X),
        (false, :none, false, X -> (x1 * x2)(X), test_X),
        (false, :none, false, X -> (x1 / (x2 + 0.1))(X), test_X),  # Add small constant to avoid division by zero
        
        # Test with unary operations
        (false, :none, false, X -> cos(x1)(X), test_X),
        (false, :none, false, X -> sin(x1)(X), test_X),
        (false, :none, false, X -> exp(x1)(X), test_X),
        (false, :none, false, X -> log(abs(x1) + 0.1)(X), test_X),  # Add small constant to ensure positive values
        
        # Test composite expressions with reductions
        (false, :none, false, X -> sum((x1 + x2)(X)), test_X),
        (false, :none, false, X -> sum(cos(x1)(X)), test_X),
        (false, :none, false, X -> mean((x1 * x2)(X)), test_X),
    ]
    
    append!(test_cases, additional_test_cases)
    
    @testset "$(typeof(fargs))" for (interface_only, perf_flag, is_primitive, fargs...) in test_cases
        test_rule(StableRNG(123456), fargs...; interface_only, perf_flag, is_primitive)
    end
end
