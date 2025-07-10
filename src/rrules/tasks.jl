# Tasks are recursively-defined, so their tangent type needs to be done manually.
# Occassionally one encountered tasks in code, but they don't actually get called. For
# example, calls to `rand` with a `TaskLocalRNG` will query the local task, purely for the
# sake of getting random number generator state associated to it.
# The goal of the code in this file is to ensure that this kind of usage of tasks is handled
# well, rather than attempting to properly handle tasks.

# The :next field is recursive (Union{Task, Nothing}), so we handle it separately
mutable struct TaskTangent{NT}
    next::Union{TaskTangent{NT}, NoTangent}
    fields::NT
    
    # Constructor for uninitialized TaskTangent (used in cycles)
    TaskTangent{NT}() where {NT} = new{NT}()
    
    # Constructor with fields
    function TaskTangent{NT}(next::Union{TaskTangent{NT}, NoTangent}, fields::NT) where {NT}
        return new{NT}(next, fields)
    end
    
    # Constructor from NamedTuple (required by Mooncake's internal machinery)
    function TaskTangent{NT}(nt::NamedTuple) where {NT}
        next_tangent = get(nt, :next, NoTangent())
        # Extract non-recursive fields by reconstructing without :next
        field_names = filter(x -> x != :next, keys(nt))
        field_values = map(n -> nt[n], field_names)
        non_recursive_fields = NamedTuple{Tuple(field_names)}(field_values)
        return new{NT}(next_tangent, non_recursive_fields)
    end
end

# Define the tangent type for Task
@generated function tangent_type(::Type{Task})
    # Get all field names and types
    field_names = fieldnames(Task)
    field_types = fieldtypes(Task)
    
    # Create tangent types for all non-recursive fields
    non_recursive_names = filter(name -> name != :next, field_names)
    non_recursive_indices = [findfirst(==(name), field_names) for name in non_recursive_names]
    non_recursive_types = [field_types[i] for i in non_recursive_indices]
    
    # Generate tangent type expressions for non-recursive fields
    tangent_type_exprs = map(T -> :(tangent_type($T)), non_recursive_types)
    
    # Build the NamedTuple type for non-recursive fields
    NT_expr = Expr(:curly, :NamedTuple, 
                   Expr(:tuple, QuoteNode.(non_recursive_names)...),
                   Expr(:curly, :Tuple, tangent_type_exprs...))
    
    return :(TaskTangent{$NT_expr})
end

function zero_tangent_internal(p::Task, dict::MaybeCache)
    T = tangent_type(Task)
    
    if haskey(dict, p)
        return dict[p]::T
    else
        # Create uninitialized tangent to handle cycles
        t = T()
        dict[p] = t
        
        # Handle the recursive :next field
        next_tangent = if p.next === nothing
            NoTangent()
        else
            zero_tangent_internal(p.next, dict)
        end
        
        # Create tangents for non-recursive fields using standard machinery
        field_names = fieldnames(Task)
        field_values = map(1:fieldcount(Task)) do i
            name = fieldnames(Task)[i]
            if name === :next
                return nothing  # Skip, handled separately
            else
                field_type = fieldtypes(Task)[i]
                if isdefined(p, i)
                    return zero_tangent_internal(getfield(p, i), dict)
                else
                    return PossiblyUninitTangent{tangent_type(field_type)}()
                end
            end
        end
        
        # Filter out the :next field and create NamedTuple for non-recursive fields
        non_recursive_indices = findall(i -> fieldnames(Task)[i] != :next, 1:fieldcount(Task))
        non_recursive_names = [fieldnames(Task)[i] for i in non_recursive_indices]
        non_recursive_values = [field_values[i] for i in non_recursive_indices]
        fields = NamedTuple{Tuple(non_recursive_names)}(non_recursive_values)
        
        # Initialize the tangent
        t.next = next_tangent
        t.fields = fields
        return t
    end
end

function randn_tangent_internal(rng::AbstractRNG, p::Task, dict::MaybeCache)
    T = tangent_type(Task)
    
    if haskey(dict, p)
        return dict[p]::T
    else
        # Create uninitialized tangent to handle cycles
        t = T()
        dict[p] = t
        
        # Handle the recursive :next field
        next_tangent = if p.next === nothing
            NoTangent()
        else
            randn_tangent_internal(rng, p.next, dict)
        end
        
        # Create tangents for non-recursive fields using standard machinery
        field_names = fieldnames(Task)
        field_values = map(1:fieldcount(Task)) do i
            name = fieldnames(Task)[i]
            if name === :next
                return nothing  # Skip, handled separately
            else
                field_type = fieldtypes(Task)[i]
                if isdefined(p, i)
                    return randn_tangent_internal(rng, getfield(p, i), dict)
                else
                    return PossiblyUninitTangent{tangent_type(field_type)}()
                end
            end
        end
        
        # Filter out the :next field and create NamedTuple for non-recursive fields
        non_recursive_indices = findall(i -> fieldnames(Task)[i] != :next, 1:fieldcount(Task))
        non_recursive_names = [fieldnames(Task)[i] for i in non_recursive_indices]
        non_recursive_values = [field_values[i] for i in non_recursive_indices]
        fields = NamedTuple{Tuple(non_recursive_names)}(non_recursive_values)
        
        # Initialize the tangent
        t.next = next_tangent
        t.fields = fields
        return t
    end
end

increment_internal!!(::IncCache, t::TaskTangent, s::TaskTangent) = t

set_to_zero_internal!!(::IncCache, t::TaskTangent) = t

_add_to_primal_internal(::MaybeCache, p::Task, t::TaskTangent, ::Bool) = p

_diff_internal(::MaybeCache, ::Task, ::Task) = zero_tangent_internal(Task(() -> nothing), IdDict())

_dot_internal(::MaybeCache, ::TaskTangent, ::TaskTangent) = 0.0

_scale_internal(::MaybeCache, ::Float64, t::TaskTangent) = t

TestUtils.populate_address_map_internal(m::TestUtils.AddressMap, ::Task, ::TaskTangent) = m

tangent(t::TaskTangent, ::NoRData) = t

@inline function _get_fdata_field(_, t::TaskTangent, f)
    if f === :next
        return t.next === NoTangent() ? NoFData() : t.next
    else
        return hasfield(typeof(t.fields), f) ? getfield(t.fields, f) : NoFData()
    end
end

set_tangent_field!(t::TaskTangent, f::Symbol, new) = begin
    if hasfield(typeof(t.fields), f)
        t.fields = Base.setindex(t.fields, new, f)
    end
    return new
end

@inline increment_field_rdata!(dx::TaskTangent, dy_rdata, ::Val{f}) where {f} = begin
    current_tangent = get_tangent_field(dx, f)
    # Handle case where we have NoTangent but need to add a real gradient
    if current_tangent isa NoTangent && !(dy_rdata isa NoRData)
        # Replace NoTangent with zero tangent of the appropriate type
        current_tangent = zero_tangent(dy_rdata)
    end
    set_tangent_field!(dx, f, increment_rdata!!(current_tangent, dy_rdata))
    dx
end

function get_tangent_field(t::TaskTangent, f)
    if f === :next
        return t.next
    else
        return hasfield(typeof(t.fields), f) ? getfield(t.fields, f) : NoTangent()
    end
end

const TaskCoDual = CoDual{Task,<:TaskTangent}

function rrule!!(::CoDual{typeof(lgetfield)}, x::TaskCoDual, ::CoDual{Val{f}}) where {f}
    dx = x.dx
    function mutable_lgetfield_pb!!(dy)
        increment_field_rdata!(dx, dy, Val{f}())
        return NoRData(), NoRData(), NoRData()
    end
    y = CoDual(getfield(x.x, f), _get_fdata_field(x.x, x.dx, f))
    return y, mutable_lgetfield_pb!!
end

set_tangent_field!(t::TaskTangent, f, ::NoTangent) = NoTangent()

@zero_adjoint MinimalCtx Tuple{typeof(current_task)}

__verify_fdata_value(::IdDict{Any,Nothing}, ::Task, ::TaskTangent) = nothing

function generate_hand_written_rrule!!_test_cases(rng_ctor, ::Val{:tasks})
    test_cases = Any[
        (false, :none, nothing, lgetfield, Task(() -> nothing), Val(:rngState1)),
        (false, :none, nothing, getfield, Task(() -> nothing), :rngState1),
        (
            false,
            :none,
            nothing,
            lsetfield!,
            Task(() -> nothing),
            Val(:rngState1),
            UInt64(5),
        ),
        (false, :stability, nothing, current_task),
    ]
    memory = Any[]
    return test_cases, memory
end

function generate_derived_rrule!!_test_cases(rng_ctor, ::Val{:tasks})
    test_cases = Any[(
        false,
        :none,
        nothing,
        (rng) -> (Random.seed!(rng, 0); rand(rng)),
        Random.default_rng(),
    ),]
    memory = Any[]
    return test_cases, memory
end
