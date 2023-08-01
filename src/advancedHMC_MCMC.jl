using AdvancedHMC, ForwardDiff, LogDensityProblems, LinearAlgebra, Distributions, Functors,
      MCMCChains

mutable struct LogTargetDensity{C, S, I}
    dim::Int
    prob::DiffEqBase.DEProblem
    chain::C
    st::S
    dataset::Vector{Vector{Float64}}
    priors::Vector{Distribution}
    phystd::Vector{Float64}
    l2std::Vector{Float64}
    autodiff::Bool
    physdt::Float64
    extraparams::Int
    init_params::I

    function LogTargetDensity(dim, prob, chain::Optimisers.Restructure, st, dataset,
                              priors, phystd, l2std, autodiff, physdt, extraparams,
                              init_params::AbstractVector)
        new{typeof(chain), Nothing, typeof(init_params)}(dim, prob, chain, nothing,
                                                         dataset, priors,
                                                         phystd, l2std, autodiff,
                                                         physdt, extraparams, init_params)
    end
    function LogTargetDensity(dim, prob, chain::Lux.AbstractExplicitLayer, st, dataset,
                              priors, phystd, l2std, autodiff, physdt, extraparams,
                              init_params::NamedTuple)
        new{typeof(chain), typeof(st), typeof(init_params)}(dim, prob, chain, st,
                                                            dataset, priors,
                                                            phystd, l2std, autodiff,
                                                            physdt, extraparams,
                                                            init_params)
    end
end

function LogDensityProblems.logdensity(Tar::LogTargetDensity, θ)
    return physloglikelihood(Tar, θ) + priorweights(Tar, θ) + L2LossData(Tar, θ)
end

LogDensityProblems.dimension(Tar::LogTargetDensity) = Tar.dim

function LogDensityProblems.capabilities(::LogTargetDensity)
    LogDensityProblems.LogDensityOrder{1}()
end

function generate_Tar(chain::Lux.AbstractExplicitLayer, init_params)
    θ, st = Lux.setup(Random.default_rng(), chain)
    return init_params, chain, st
end

function generate_Tar(chain::Lux.AbstractExplicitLayer, init_params::Nothing)
    θ, st = Lux.setup(Random.default_rng(), chain)
    return θ, chain, st
end

function generate_Tar(chain::Flux.Chain, init_params)
    θ, re = Flux.destructure(chain)
    return init_params, re, nothing
end

function generate_Tar(chain::Flux.Chain, init_params::Nothing)
    θ, re = Flux.destructure(chain)
    # find_good_stepsize,phasepoint takes only float64
    θ = collect(Float64, θ)
    return θ, re, nothing
end

# For vector of samples to Lux ComponentArrays
function vector_to_parameters(ps_new::AbstractVector, ps::NamedTuple)
    @assert length(ps_new) == Lux.parameterlength(ps)
    i = 1
    function get_ps(x)
        z = reshape(view(ps_new, i:(i + length(x) - 1)), size(x))
        i += length(x)
        return z
    end
    return Functors.fmap(get_ps, ps)
end

# nn OUTPUT AT t
function (f::LogTargetDensity{C, S})(t::AbstractVector,
                                     θ) where {C <: Optimisers.Restructure, S}
    f.prob.u0 .+ (t' .- f.prob.tspan[1]) .* f.chain(θ)(adapt(parameterless_type(θ), t'))
end

function (f::LogTargetDensity{C, S})(t::AbstractVector,
                                     θ) where {C <: Lux.AbstractExplicitLayer, S}
    θ = vector_to_parameters(θ, f.init_params)
    y, st = f.chain(adapt(parameterless_type(ComponentArrays.getdata(θ)), t'), θ, f.st)
    ChainRulesCore.@ignore_derivatives f.st = st
    f.prob.u0 .+ (t' .- f.prob.tspan[1]) .* y
end

function (f::LogTargetDensity{C, S})(t::Number,
                                     θ) where {C <: Optimisers.Restructure, S}
    #  must handle paired odes hence u0 broadcasted
    f.prob.u0 .+ (t - f.prob.tspan[1]) * f.chain(θ)(adapt(parameterless_type(θ), [t]))
end

function (f::LogTargetDensity{C, S})(t::Number,
                                     θ) where {C <: Lux.AbstractExplicitLayer, S}
    θ = vector_to_parameters(θ, f.init_params)
    y, st = f.chain(adapt(parameterless_type(ComponentArrays.getdata(θ)), [t]), θ, f.st)
    ChainRulesCore.@ignore_derivatives f.st = st
    f.prob.u0 .+ (t .- f.prob.tspan[1]) .* y
end

# ODE DU/DX
function NNodederi(phi::LogTargetDensity, t::AbstractVector, θ, autodiff::Bool)
    if autodiff
        hcat(ForwardDiff.derivative.(ti -> phi(ti, θ), t)...)
    else
        (phi(t .+ sqrt(eps(eltype(t))), θ) - phi(t, θ)) ./ sqrt(eps(eltype(t)))
    end
end

# physics loglikelihood over problem timespan
function physloglikelihood(Tar::LogTargetDensity, θ)
    f = Tar.prob.f
    p = Tar.prob.p
    dt = Tar.physdt
    if isempty(Tar.dataset[end])
        t = collect(Float64, Tar.prob.tspan[1]:dt:Tar.prob.tspan[2])
    else
        t = vcat(collect(Float64, Tar.prob.tspan[1]:dt:Tar.prob.tspan[2]), Tar.dataset[end])
    end

    # parameter estimation chosen or not
    if Tar.extraparams > 0
        ode_params = Tar.extraparams == 1 ?
                     θ[((length(θ) - Tar.extraparams) + 1):length(θ)][1] :
                     θ[((length(θ) - Tar.extraparams) + 1):length(θ)]
    else
        ode_params = p == SciMLBase.NullParameters() ? [] : p
    end

    # train for NN deriative upon dataset as well as beyond but within timespan
    autodiff = Tar.autodiff

    # compare derivatives(matrix)
    out = Tar(t, θ[1:(length(θ) - Tar.extraparams)])

    # reject samples case
    if any(isinf, out[:, 1]) || any(isinf, ode_params)
        return -Inf
    end

    # this is a vector{vector{dx,dy}}(handle case single u(float passed))
    if length(out[:, 1]) == 1
        physsol = [f(out[:, i][1],
                     ode_params,
                     t[i])
                   for i in 1:length(out[1, :])]
    else
        physsol = [f(out[:, i],
                     ode_params,
                     t[i])
                   for i in 1:length(out[1, :])]
    end
    physsol = hcat(physsol...)

    # convert to matrix as nnsol
    nnsol = NNodederi(Tar, t, θ[1:(length(θ) - Tar.extraparams)], autodiff)

    physlogprob = 0
    for i in 1:length(Tar.prob.u0)
        # can add phystd[i] for u[i]
        physlogprob += logpdf(MvNormal(nnsol[i, :], Tar.phystd[i]), physsol[i, :])
    end
    return physlogprob
end

# L2 losses loglikelihood(needed mainly for ODE parameter estimation)
function L2LossData(Tar::LogTargetDensity, θ)
    # matrix(each row corresponds to vector u's rows)
    if isempty(Tar.dataset[end])
        return 0
    else
        nn = Tar(Tar.dataset[end], θ[1:(length(θ) - Tar.extraparams)])

        L2logprob = 0
        for i in 1:length(Tar.prob.u0)
            # for u[i] ith vector must be added to dataset,nn[1,:] is the dx in lotka_volterra
            L2logprob += logpdf(MvNormal(nn[i, :], Tar.l2std[i]), Tar.dataset[i])
        end
        return L2logprob
    end
end

# priors for NN parameters + ODE constants
function priorweights(Tar::LogTargetDensity, θ)
    allparams = Tar.priors
    # Vector of ode parameters priors
    invpriors = allparams[2:end]

    # nn weights
    nnwparams = allparams[1]

    if Tar.extraparams > 0
        invlogpdf = sum(logpdf(invpriors[length(θ) - i + 1], θ[i])
                        for i in (length(θ) - Tar.extraparams + 1):length(θ); init = 0.0)

        return (invlogpdf
                +
                logpdf(nnwparams, θ[1:(length(θ) - Tar.extraparams)]))
    else
        return logpdf(nnwparams, θ)
    end
end

function integratorchoice(Integrator, initial_ϵ; jitter_rate = 3.0,
                          tempering_rate = 3.0)
    if Integrator == JitteredLeapfrog
        Integrator(initial_ϵ, jitter_rate)
    elseif Integrator == TemperedLeapfrog
        Integrator(initial_ϵ, tempering_rate)
    else
        Integrator(initial_ϵ)
    end
end

function proposalchoice(Sampler, Integrator; n_steps = 50,
                        trajectory_length = 30.0)
    if Sampler == StaticTrajectory
        Sampler(Integrator, n_steps)
    elseif Sampler == AdvancedHMC.HMCDA
        Sampler(Integrator, trajectory_length)
    else
        Sampler(Integrator)
    end
end

# dataset would be (x̂,t)
# priors: pdf for W,b + pdf for ODE params
# lotka specific kwargs here

function ahmc_bayesian_pinn_ode(prob::DiffEqBase.DEProblem, chain;
                                dataset = [[]],
                                # dataset::Vector{Vector{Float64}}
                                init_params = nothing, nchains = 1,
                                draw_samples = 1000, l2std = [0.05],
                                phystd = [0.05], priorsNNw = (0.0, 2.0),
                                param = [],
                                autodiff = false, physdt = 1 / 20.0f0,
                                Proposal = StaticTrajectory,
                                Adaptor = StanHMCAdaptor, targetacceptancerate = 0.8,
                                Integrator = Leapfrog,
                                Metric = DiagEuclideanMetric)

    # NN parameter prior mean and variance(PriorsNN must be a tuple)
    if isinplace(prob)
        throw(error("The BPINN ODE solver only supports out-of-place ODE definitions, i.e. du=f(u,p,t)."))
    end

    if chain isa Lux.AbstractExplicitLayer || chain isa Flux.Chain
        # Flux-vector, Lux-Named Tuple
        initial_nnθ, recon, st = generate_Tar(chain, init_params)
    else
        error("Only Lux.AbstractExplicitLayer and Flux.Chain neural networks are supported")
    end

    if nchains > Threads.nthreads()
        throw(error("number of chains is greater than available threads"))
    elseif nchains < 1
        throw(error("number of chains must be greater than 1"))
    end

    # 
    if chain isa Lux.AbstractExplicitLayer
        # Lux chain(using component array later as vector_to_parameter need namedtuple,AHMC uses Float64)
        initial_θ = collect(Float64, vcat(ComponentArrays.ComponentArray(initial_nnθ)))
    else
        initial_θ = initial_nnθ
    end

    # adding ode parameter estimation
    nparameters = length(initial_θ)
    ninv = length(param)
    priors = [MvNormal(priorsNNw[1] * ones(nparameters), priorsNNw[2] * ones(nparameters))]

    # append Ode params to all paramvector
    if ninv > 0
        # shift ode params(initialise ode params by prior means)
        initial_θ = vcat(initial_θ, [Distributions.params(param[i])[1] for i in 1:ninv])
        priors = vcat(priors, param)
        nparameters += ninv
    end

    t0 = prob.tspan[1]
    # dimensions would be total no of params,initial_nnθ for Lux namedTuples
    ℓπ = LogTargetDensity(nparameters, prob, recon, st, dataset, priors,
                          phystd, l2std, autodiff, physdt, ninv,
                          initial_nnθ)

    try
        ℓπ(t0, initial_θ[1:(nparameters - ninv)])
    catch err
        if isa(err, DimensionMismatch)
            throw(DimensionMismatch("Dimensions of the initial u0 and chain should match"))
        else
            throw(err)
        end
    end

    # Define Hamiltonian system
    metric = Metric(nparameters)
    hamiltonian = Hamiltonian(metric, ℓπ, ForwardDiff)

    # parallel sampling option
    if nchains != 1
        # Cache to store the chains
        chains = Vector{Any}(undef, nchains)
        statsc = Vector{Any}(undef, nchains)
        samplesc = Vector{Any}(undef, nchains)

        Threads.@threads for i in 1:nchains
            # each chain has different initial NNparameter values(better posterior exploration)
            initial_θ = vcat(randn(nparameters - ninv),
                             initial_θ[(nparameters - ninv + 1):end])
            initial_ϵ = find_good_stepsize(hamiltonian, initial_θ)
            integrator = integratorchoice(Integrator, initial_ϵ)
            proposal = proposalchoice(Proposal, integrator)
            adaptor = Adaptor(MassMatrixAdaptor(metric),
                              StepSizeAdaptor(targetacceptancerate, integrator))

            samples, stats = sample(hamiltonian, proposal, initial_θ, draw_samples, adaptor;
                                    progress = true, verbose = false)
            samplesc[i] = samples
            statsc[i] = stats

            mcmc_chain = Chains(hcat(samples...)')
            chains[i] = mcmc_chain
        end

        return chains, samplesc, statsc
    else
        initial_ϵ = find_good_stepsize(hamiltonian, initial_θ)
        integrator = integratorchoice(Integrator, initial_ϵ)
        proposal = proposalchoice(Proposal, integrator)
        adaptor = Adaptor(MassMatrixAdaptor(metric),
                          StepSizeAdaptor(targetacceptancerate, integrator))

        samples, stats = sample(hamiltonian, proposal, initial_θ, draw_samples, adaptor;
                                progress = true)
        # return a chain(basic chain),samples and stats
        matrix_samples = hcat(samples...)
        mcmc_chain = MCMCChains.Chains(matrix_samples')
        return mcmc_chain, samples, stats
    end
end