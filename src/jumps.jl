struct ConstantRateJump{F1,F2} <: AbstractJump
  rate::F1
  affect!::F2
end

struct VariableRateJump{R,F,I,T,T2} <: AbstractJump
  rate::R
  affect!::F
  idxs::I
  rootfind::Bool
  interp_points::Int
  save_positions::Tuple{Bool,Bool}
  abstol::T
  reltol::T2
end

"""
Salis H., Kaznessis Y.,  Accurate hybrid stochastic simulation of a system of
coupled chemical or biochemical reactions, Journal of Chemical Physics, 122 (5),
DOI:10.1063/1.1835951
"""
VariableRateJump(rate,affect!;
                   idxs = nothing,
                   rootfind=true,
                   save_positions=(true,true),
                   interp_points=10,
                   abstol=1e-12,reltol=0) = VariableRateJump(
                              rate,affect!,idxs,
                              rootfind,interp_points,
                              save_positions,abstol,reltol)

struct RegularJump{iip,R,C,MD}
    rate::R
    c::C
    numjumps::Int
    mark_dist::MD
    function RegularJump{iip}(rate,c,numjumps::Int; mark_dist = nothing) where iip
      new{iip,typeof(rate),typeof(c),typeof(mark_dist)}(rate,c,numjumps,mark_dist)
    end
end

DiffEqBase.isinplace(::RegularJump{iip,R,C,MD}) where {iip,R,C,MD} = iip

RegularJump(rate,c,numjumps::Int; kwargs...) = RegularJump{DiffEqBase.isinplace(rate,4)}(rate,c,numjumps;kwargs...)

# deprecate old call
function RegularJump(rate,c,dc::AbstractMatrix; constant_c=false, mark_dist = nothing)
  @warn("The RegularJump interface has changed to be matrix-free. See the documentation for more details.")
  function _c(du,u,p,t,counts,mark)
    c(dc,u,p,t,mark)
    mul!(du,dc,counts)
  end
  RegularJump{true}(rate,_c,size(dc,2);mark_dist=mark_dist)
end

struct MassActionJump{T,S,U,V} <: AbstractJump
  scaled_rates::T
  reactant_stoch::S
  net_stoch::U
  param_mapper::V

  function MassActionJump{T,S,U,V}(rates::T, rs_in::S, ns::U, pmapper::V, scale_rates::Bool, useiszero::Bool, nocopy::Bool) where {T <: AbstractVector, S, U, V}
    sr  = nocopy ? rates : copy(rates)
    rs = nocopy ? rs_in : copy(rs_in)
    for i in eachindex(rs)
      if useiszero && (length(rs[i]) == 1) && iszero(rs[i][1][1])
        rs[i] = typeof(rs[i])()
      end
    end

    if scale_rates && !isempty(sr)
      scalerates!(sr, rs)
    end
    new(sr, rs, ns, pmapper)
  end
  function MassActionJump{Nothing,Vector{S},Vector{U},V}(::Nothing, rs_in::Vector{S}, ns::Vector{U}, pmapper::V, scale_rates::Bool, useiszero::Bool, nocopy::Bool) where {S<:AbstractVector, U<:AbstractVector, V}
    rs = nocopy ? rs_in : copy(rs_in)
    for i in eachindex(rs)
      if useiszero && (length(rs[i]) == 1) && iszero(rs[i][1][1])
        rs[i] = typeof(rs[i])()
      end
    end
    new(nothing, rs, ns, pmapper)
  end
  function MassActionJump{T,S,U,V}(rate::T, rs_in::S, ns::U, pmapper::V, scale_rates::Bool, useiszero::Bool, nocopy::Bool) where {T <: Number, S, U, V}
    rs = rs_in
    if useiszero && (length(rs) == 1) && iszero(rs[1][1])
      rs = typeof(rs)()
    end
    sr = scale_rates ? scalerate(rate, rs) : rate
    new(sr, rs, ns, pmapper)
  end
  function MassActionJump{Nothing,S,U,V}(::Nothing, rs_in::S, ns::U, pmapper::V, scale_rates::Bool, useiszero::Bool, nocopy::Bool) where {S, U, V}
    rs = rs_in
    if useiszero && (length(rs) == 1) && iszero(rs[1][1])
      rs = typeof(rs)()
    end
    new(nothing, rs, ns, pmapper)
  end

end
MassActionJump(usr::T, rs::S, ns::U, pmapper::V; scale_rates = true, useiszero = true, nocopy=false) where {T,S,U,V} = MassActionJump{T,S,U,V}(usr, rs, ns, pmapper, scale_rates, useiszero, nocopy)
MassActionJump(usr::T, rs, ns; scale_rates = true, useiszero = true, nocopy=false) where {T <: AbstractVector,S,U} = MassActionJump(usr, rs, ns, nothing; scale_rates=scale_rates, useiszero=useiszero, nocopy=nocopy)
MassActionJump(usr::T, rs, ns; scale_rates = true, useiszero = true, nocopy=false) where {T <: Number,S,U} = MassActionJump(usr, rs, ns, nothing; scale_rates=scale_rates, useiszero=useiszero, nocopy=nocopy)

# with parameter indices or mapping, multiple jump case
function MassActionJump(rs, ns; param_idxs=nothing, param_mapper=nothing, scale_rates = true, useiszero = true, nocopy=false)
  if param_mapper === nothing 
    (param_idxs === nothing) && error("If no parameter indices are given via param_idxs, an explicit parameter mapping must be passed in via param_mapper.")
    pmapper = MassActionJumpParamMapper(param_idxs)
  else
    (param_idxs !== nothing) && error("Only one of param_idxs and param_mapper should be passed.")
    pmapper = param_mapper
  end
                      
  MassActionJump(nothing, nocopy ? rs : copy(rs), ns, pmapper; scale_rates=scale_rates, 
                 useiszero=useiszero, nocopy=true)
end

using_params(maj::MassActionJump{T,S,U,Nothing}) where {T,S,U} = false
using_params(maj::MassActionJump) = true
using_params(maj::Nothing) = false
@inline get_num_majumps(maj::MassActionJump) = length(maj.scaled_rates)
@inline get_num_majumps(maj::Nothing) = 0

struct MassActionJumpParamMapper{U}
  param_idxs::U
end

# create the initial parameter vector for use in a MassActionJump
# Note these are unscaled
function (ratemap::MassActionJumpParamMapper{U})(params) where {U <: AbstractArray}
  [params[pidx] for pidx in ratemap.param_idxs]
end

# Note this is unscaled
function (ratemap::MassActionJumpParamMapper{U})(params) where {U <: Int}
  params[ratemap.param_idxs]
end

# update a maj with parameter vectors
function (ratemap::MassActionJumpParamMapper{U})(maj::MassActionJump, newparams; scale_rates, kwargs...) where {U <: AbstractArray}
  for i in 1:get_num_majumps(maj)
    maj.scaled_rates[i] = newparams[ratemap.param_idxs[i]]    
  end
  scale_rates && scalerates!(maj.scaled_rates, maj.reactant_stoch)
  nothing
end

function to_collection(ratemap::MassActionJumpParamMapper{Int})  
  MassActionJumpParamMapper([ratemap.param_idxs])
end

function Base.merge!(pmap1::MassActionJumpParamMapper{U}, pmap2::MassActionJumpParamMapper{U}) where {U <: AbstractVector}
  append!(pmap1.param_idxs, pmap2.param_idxs)
end

function Base.merge!(pmap1::MassActionJumpParamMapper{U}, pmap2::MassActionJumpParamMapper{V}) where {U <: AbstractVector, V <: Int}
  push!(pmap1.param_idxs, pmap2.param_idxs)
end

function Base.merge(pmap1::MassActionJumpParamMapper{Int}, pmap2::MassActionJumpParamMapper{Int})  
  MassActionJumpParamMapper([pmap1.param_idxs, pmap2.param_idxs])
end

"""
  update_parameters!(maj::MassActionJump, newparams; scale_rates=true)

Updates the passed in MassActionJump with the parameter values in `newparams`.

Notes:
  - Requires the jump to have been constructed with a user-passed `param_idxs` or `param_mapper`.
  - `scale_rates=true` will scale the parameter representing the jump rate by an
    appropriate combinatoric factor. i.e for 3A --> B at rate k it will scale
    k --> k/3!.
"""
function update_parameters!(maj::MassActionJump, newparams; scale_rates=true, kwargs...) 
  (maj.param_mapper === nothing) && error("MassActionJumps must be constructed with param_idxs or a param_mapper to be updateable.")
  maj.param_mapper(maj, newparams; scale_rates, kwargs)
end

struct JumpSet{T1,T2,T3,T4} <: AbstractJump
  variable_jumps::T1
  constant_jumps::T2
  regular_jump::T3
  massaction_jump::T4
end
JumpSet(vj, cj, rj, maj::MassActionJump{S,T,U,V}) where {S <: Number,T,U,V} = JumpSet(vj, cj, rj, check_majump_type(maj))

JumpSet(jump::ConstantRateJump) = JumpSet((),(jump,),nothing,nothing)
JumpSet(jump::VariableRateJump) = JumpSet((jump,),(),nothing,nothing)
JumpSet(jump::RegularJump)      = JumpSet((),(),jump,nothing)
JumpSet(jump::MassActionJump)   = JumpSet((),(),nothing,jump)
function JumpSet(; variable_jumps=(), constant_jumps=(), 
                   regular_jumps=nothing, massaction_jumps=nothing) 
  JumpSet(variable_jumps, constant_jumps, regular_jumps, massaction_jumps)
end
JumpSet(jb::Nothing) = JumpSet()

# For Varargs, use recursion to make it type-stable
JumpSet(jumps::AbstractJump...) = JumpSet(split_jumps((), (), nothing, nothing, jumps...)...)

# handle vector of mass action jumps
function JumpSet(vjs, cjs, rj, majv::Vector{T}) where {T <: MassActionJump}
  if isempty(majv)
    error("JumpSets do not accept empty mass action jump collections; use \"nothing\" instead.")
  end

  maj = setup_majump_to_merge(majv[1].scaled_rates, majv[1].reactant_stoch, majv[1].net_stoch, majv[1].param_mapper)
  for i = 2:length(majv)
    massaction_jump_combine(maj, majv[i])
  end

  JumpSet(vjs, cjs, rj, maj)
end

@inline get_num_majumps(jset::JumpSet) = get_num_majumps(jset.massaction_jump)


@inline split_jumps(vj, cj, rj, maj) = vj, cj, rj, maj
@inline split_jumps(vj, cj, rj, maj, v::VariableRateJump, args...) = split_jumps((vj..., v), cj, rj, maj, args...)
@inline split_jumps(vj, cj, rj, maj, c::ConstantRateJump, args...) = split_jumps(vj, (cj..., c), rj, maj, args...)
@inline split_jumps(vj, cj, rj, maj, c::RegularJump, args...) = split_jumps(vj, cj, regular_jump_combine(rj,c), maj, args...)
@inline split_jumps(vj, cj, rj, maj, c::MassActionJump, args...) = split_jumps(vj, cj, rj, massaction_jump_combine(maj,c), args...)
@inline split_jumps(vj, cj, rj, maj, j::JumpSet, args...) = split_jumps((vj...,j.variable_jumps...),
                                                                        (cj..., j.constant_jumps...),
                                                                        regular_jump_combine(rj,j.regular_jump),
                                                                        massaction_jump_combine(maj,j.massaction_jump), args...)

regular_jump_combine(rj1::RegularJump,rj2::Nothing) = rj1
regular_jump_combine(rj1::Nothing,rj2::RegularJump) = rj2
regular_jump_combine(rj1::Nothing,rj2::Nothing) = rj1
regular_jump_combine(rj1::RegularJump,rj2::RegularJump) = error("Only one regular jump is allowed in a JumpSet")


# functionality to merge two mass action jumps together
check_majump_type(maj::MassActionJump{S,T,U,V}) where {S <: Number,T,U,V} = setup_majump_to_merge(maj.scaled_rates, maj.reactant_stoch, maj.net_stoch, maj.param_mapper)
check_majump_type(maj::MassActionJump{Nothing,T,U,V}) where {T,U,V} = setup_majump_to_merge(maj.scaled_rates, maj.reactant_stoch, maj.net_stoch, maj.param_mapper)

# if given containers of rates and stoichiometry directly create a jump
function setup_majump_to_merge(sr::T, rs::AbstractVector{S}, ns::AbstractVector{U}, pmapper) where {T <: AbstractVector, S <: AbstractArray, U <: AbstractArray}
   MassActionJump(sr, rs, ns, pmapper; scale_rates=false)
end

# if just given the data for one jump (and not in a container) wrap in a vector
function setup_majump_to_merge(sr::S, rs::T, ns::U, pmapper) where {S <: Number, T <: AbstractArray, U <: AbstractArray}  
  MassActionJump([sr], [rs], [ns], (pmapper === nothing) ? pmapper : to_collection(pmapper); scale_rates=false)
end

# if no rate field setup yet
function setup_majump_to_merge(::Nothing, rs::T, ns::U, pmapper) where {T <: AbstractArray, U <: AbstractArray}  
  MassActionJump(nothing, [rs], [ns], (pmapper === nothing) ? pmapper : to_collection(pmapper); scale_rates=false)
end

# when given a collection of reactions to add to maj
function majump_merge!(maj::MassActionJump{U,<:AbstractVector{V},<:AbstractVector{W},X}, sr::U, rs::AbstractVector{V}, ns::AbstractVector{W}, param_mapper) where {U <: Union{AbstractVector,Nothing}, V <: AbstractVector, W <: AbstractVector, X}
  (U <: AbstractVector) && append!(maj.scaled_rates, sr)
  append!(maj.reactant_stoch, rs)
  append!(maj.net_stoch, ns)
  if maj.param_mapper === nothing
    (param_mapper === nothing) || error("Error, trying to merge a MassActionJump with a parameter mapping to one without a parameter mapping.")    
  else
    merge!(maj.param_mapper, param_mapper)
  end
  maj
end

# when given a single jump's worth of data to add to maj
function majump_merge!(maj::MassActionJump{U,V,W,X}, sr::T, rs::S1, ns::S2, param_mapper) where {T <: Union{Number,Nothing}, S1 <: AbstractArray, S2 <: AbstractArray, U <: Union{AbstractVector{T},Nothing}, V <: AbstractVector{S1}, W <: AbstractVector{S2}, X}
  (T <: Number) && push!(maj.scaled_rates, sr)
  push!(maj.reactant_stoch, rs)
  push!(maj.net_stoch, ns)
  if maj.param_mapper === nothing
    (param_mapper === nothing) || error("Error, trying to merge a MassActionJump with a parameter mapping to one without a parameter mapping.")    
  else
    merge!(maj.param_mapper, param_mapper)
  end
    
  maj
end

# when maj only stores a single jump's worth of data (and not in a collection)
# create a new jump with the merged data stored in vectors
function majump_merge!(maj::MassActionJump{T,S,U,V}, sr::T, rs::S, ns::U, param_mapper::V) where {T <: Union{Number,Nothing}, S <: AbstractArray{<:Pair}, U <: AbstractArray{<:Pair}, V}
  rates = (T <: Nothing) ? nothing : [maj.scaled_rates, sr]
  if maj.param_mapper === nothing
    (param_mapper === nothing) || error("Error, trying to merge a MassActionJump with a parameter mapping to one without a parameter mapping.")    
    return MassActionJump(rates, [maj.reactant_stoch, rs], [maj.net_stoch, ns], param_mapper; scale_rates=false)
  else
    return MassActionJump(rates, [maj.reactant_stoch, rs], [maj.net_stoch, ns], merge(maj.param_mapper,param_mapper); scale_rates=false)
  end
end

massaction_jump_combine(maj1::MassActionJump, maj2::Nothing) = maj1
massaction_jump_combine(maj1::Nothing, maj2::MassActionJump) = maj2
massaction_jump_combine(maj1::Nothing, maj2::Nothing) = maj1
massaction_jump_combine(maj1::MassActionJump, maj2::MassActionJump) = majump_merge!(maj1, maj2.scaled_rates, maj2.reactant_stoch, maj2.net_stoch, maj2.param_mapper)


##### helper methods for unpacking rates and affects! from constant jumps #####
function get_jump_info_tuples(constant_jumps)
  if (constant_jumps !== nothing) && !isempty(constant_jumps)
    rates    = ((c.rate for c in constant_jumps)...,)
    affects! = ((c.affect! for c in constant_jumps)...,)
  else
    rates    = ()
    affects! = ()
  end

  rates, affects!
end

function get_jump_info_fwrappers(u, p, t, constant_jumps)
  RateWrapper   = FunctionWrappers.FunctionWrapper{typeof(t),Tuple{typeof(u), typeof(p), typeof(t)}}
  AffectWrapper = FunctionWrappers.FunctionWrapper{Nothing,Tuple{Any}}

  if (constant_jumps !== nothing) && !isempty(constant_jumps)
    rates    = [RateWrapper(c.rate) for c in constant_jumps]
    affects! = [AffectWrapper(x->(c.affect!(x);nothing)) for c in constant_jumps]
  else
    rates    = Vector{RateWrapper}()
    affects! = Vector{AffectWrapper}()
  end

  rates, affects!
end
