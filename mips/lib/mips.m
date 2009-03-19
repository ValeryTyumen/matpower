function [x, f, info, Output, Lambda] = pdipm(ipm_f, ipm_gh, ipm_hess, x0, xmin, xmax, A, l, u, opt)
%PDIPM  Primal-dual interior point method for NLP.
%   [x, f, info, Output, Lambda] = ...
%       pdipm(f, gh, hess, x0, xmin, xmax, A, l, u, opt)
%
%   min f(x)
%    s.t.
%   h(x) = 0
%   g(x) <= 0
%   l <= A*x <= u
%   xmin <= x <= xmax

%   MATPOWER
%   $Id$
%   by Ray Zimmerman, PSERC Cornell
%   Copyright (c) 2009 by Power System Engineering Research Center (PSERC)
%   See http://www.pserc.cornell.edu/matpower/ for more info.

%% options
if nargin < 10
    opt = struct([]);
    if nargin < 7
        A = []; l = []; u = [];
        if nargin < 6
            xmax = Inf * ones(size(x0));
            if nargin < 5
                xmin = -Inf * ones(size(x0));
            end
        end
    end
end
if ~isfield(opt, 'feastol') || isempty(opt.feastol)
    opt.feastol = 1e-6;
end
if ~isfield(opt, 'gradtol') || isempty(opt.gradtol)
    opt.gradtol = 1e-6;
end
if ~isfield(opt, 'comptol') || isempty(opt.comptol)
    opt.comptol = 1e-6;
end
if ~isfield(opt, 'costtol') || isempty(opt.costtol)
    opt.costtol = 1e-6;
end
if ~isfield(opt, 'max_it') || isempty(opt.max_it)
    opt.max_it = 150;
end
if ~isfield(opt, 'cost_mult') || isempty(opt.cost_mult)
    opt.cost_mult = 1;
end
if ~isfield(opt, 'verbose') || isempty(opt.verbose)
    opt.verbose = 0;
end

%% constants
xi = 0.99995;           %% OPT_IPM_PHI
sigma = 0.1;            %% OPT_IPM_SIGMA
z0 = 1;                 %% OPT_IPM_INIT_SLACK
mu_threshold = 1e-5;	%% SCOPF_MULTIPLIERS_FILTER_THRESH

%% initialize
i = 0;                      %% iteration counter
converged = 0;              %% flag
nx = size(x0, 1);           %% number of variables
nA = size(A, 1);            %% number of original linear constraints

%% add var limits to linear constraints
AA = [speye(nx); A];
ll = [xmin; l];
uu = [xmax; u];

%% split up linear constraints
ieq = find( abs(uu-ll) <= eps );            %% equality
igt = find( uu >=  1e10 & ll > -1e10 );     %% greater than, unbounded above
ilt = find( ll <= -1e10 & uu <  1e10 );     %% less than, unbounded below
ibx = find( (abs(uu-ll) > eps) & (uu < 1e10) & (ll > -1e10) );
Ae = AA(ieq, :);
be = uu(ieq);
Ai  = [ AA(ilt, :); -AA(igt, :); AA(ibx, :); -AA(ibx, :) ];
bi  = [ uu(ilt);   -ll(igt);     uu(ibx);    -ll(ibx)];

%% evaluate cost f(x0) and constraints g(x0), h(x0)
x = x0;
[f, df] = ipm_f(x);             %% cost
f = f * opt.cost_mult;
df = df * opt.cost_mult;
[gn, hn, dgn, dhn] = ipm_gh(x); %% non-linear constraints
g = [gn; Ai * x - bi];          %% inequality constraints
h = [hn; Ae * x - be];          %% equality constraints
dg = [dgn Ai'];                 %% 1st derivative of inequalities
dh = [dhn Ae'];                 %% 1st derivative of equalities

%% grab some dimensions
neq = size(h, 1);           %% number of equality constraints
niq = size(g, 1);           %% number of inequality constraints
neqnln = size(hn, 1);       %% number of non-linear equality constraints
niqnln = size(gn, 1);       %% number of non-linear inequality constraints
nlt = length(ilt);          %% number of upper bounded linear inequalities
ngt = length(igt);          %% number of lower bounded linear inequalities
nbx = length(ibx);          %% number of doubly bounded linear inequalities

%% initialize gamma, lam, mu, z, e
gamma = 1;                  %% barrier coefficient, r in Harry's code
lam = zeros(neq, 1);
z   = z0 * ones(niq, 1);
mu  = z;
k = find(g < -z0);
z(k) = -g(k);
k = find(gamma ./ z > z0);
mu(k) = gamma ./ z(k);
e = ones(niq, 1);

%% check tolerance
f0 = f;
% L = f + lam' * h + mu' * (g+z) - gamma * sum(log(z));
Lx = df + dh * lam + dg * mu;
feascond = max([norm(h, Inf), max(g)]) / (1 + max([ norm(x, Inf), norm(z, Inf) ]));
gradcond = norm(Lx, Inf) / (1 + max([ norm(lam, Inf), norm(mu, Inf) ]));
compcond = (z' * mu) / (1 + norm(x, Inf));
costcond = abs(f - f0) / (1 + abs(f0));
if opt.verbose > 1
    fprintf('\n it    objective     feascond     gradcond     compcond     costcond  ');
    fprintf('\n----  ------------ ------------ ------------ ------------ ------------');
    fprintf('\n%3d  %12g %12g %12g %12g %12g', i, f, feascond, gradcond, compcond, costcond);
end
if feascond < opt.feastol && gradcond < opt.gradtol && ...
                compcond < opt.comptol && costcond < opt.costtol
    converged = 1;
    if opt.verbose > 1
        fprintf('\nConverged!\n');
    end
end

%% do Newton iterations
while (~converged && i < opt.max_it)
    %% update iteration counter
    i = i + 1;

    %% compute update step
    lambda = struct('eqnonlin', lam(1:neqnln), 'ineqnonlin', mu(1:niqnln));
    Lxx = ipm_hess(x, lambda);
    zinvdiag = sparse(1:niq, 1:niq, 1 ./ z, niq, niq);
    mudiag = sparse(1:niq, 1:niq, mu, niq, niq);
    dg_zinv = dg * zinvdiag;
    M = Lxx + dg_zinv * mudiag * dg';
    N = Lx + dg_zinv * (mudiag * g + gamma * e);
    dxdlam = [M dh; dh' sparse(neq, neq)] \ [-N; -h];
%     AAA = [
%         M  dh;
%         dh'  sparse(neq, neq)
%     ];
%     bbb = [-N; -h];
%     dxdlam = AAA \ bbb;
    dx = dxdlam(1:nx);
    dlam = dxdlam(nx+(1:neq));
    dz = -g - z - dg' * dx;
    dmu = -mu + zinvdiag *(gamma*e - mudiag * dz);
    k = find(dz < 0);
    alphap = min( [xi * min(z(k) ./ -dz(k)) 1] );
    k = find(dmu < 0);
    alphad = min( [xi * min(mu(k) ./ -dmu(k)) 1] );

    %% do the update
    x = x + alphap * dx;
    z = z + alphap * dz;
    lam = lam + alphad * dlam;
    mu  = mu  + alphad * dmu;
    gamma = sigma * (z' * mu) / niq;

    %% evaluate cost, constraints, derivatives
    [f, df] = ipm_f(x);             %% cost
    f = f * opt.cost_mult;
    df = df * opt.cost_mult;
    [gn, hn, dgn, dhn] = ipm_gh(x); %% non-linear constraints
    g = [gn; Ai * x - bi];          %% inequality constraints
    h = [hn; Ae * x - be];          %% equality constraints
    dg = [dgn Ai'];                 %% 1st derivative of inequalities
    dh = [dhn Ae'];                 %% 1st derivative of equalities

    %% check tolerance
    Lx = df + dh * lam + dg * mu;
    feascond = max([norm(h, Inf), max(g)]) / (1 + max([ norm(x, Inf), norm(z, Inf) ]));
    gradcond = norm(Lx, Inf) / (1 + max([ norm(lam, Inf), norm(mu, Inf) ]));
    compcond = (z' * mu) / (1 + norm(x, Inf));
    costcond = abs(f - f0) / (1 + abs(f0));
    if opt.verbose > 1
        fprintf('\n%3d  %12g %12g %12g %12g %12g', i, f/opt.cost_mult, feascond, gradcond, compcond, costcond);
    end
    if feascond < opt.feastol && gradcond < opt.gradtol && ...
                    compcond < opt.comptol && costcond < opt.costtol
        converged = 1;
        if opt.verbose > 1
            fprintf('\nConverged!\n');
        end
    end
    f0 = f;
end

if opt.verbose
    if ~converged
        fprintf('\nDid not converge in %d iterations.\n', i);
    end
end

info = converged;
Output = struct('iterations', i, 'feascond', feascond, 'gradcond', gradcond, ...
                'compcond', compcond, 'costcond', costcond);

%% zero out multipliers on non-binding constraints
mu(g < -opt.feastol & mu < mu_threshold) = 0;

%% un-scale cost and prices
f   = f   / opt.cost_mult;
lam = lam / opt.cost_mult;
mu  = mu  / opt.cost_mult;

%% re-package multipliers into struct
lam_lin = lam((neqnln+1):neq);              %% lambda for linear constraints
mu_lin  = mu((niqnln+1):niq);               %% mu for linear constraints
kl = find(lam_lin < 0);                     %% lower bound binding
ku = find(lam_lin > 0);                     %% upper bound binding

mu_l = zeros(nx+nA, 1);
% mu_l = zeros(length(ll)+nx-nx, 1);
mu_l(ieq(kl)) = -lam_lin(kl);
mu_l(igt) = mu_lin(nlt+(1:ngt));
mu_l(ibx) = mu_lin(nlt+ngt+nbx+(1:nbx));

mu_u = zeros(nx+nA, 1);
mu_u(ieq(ku)) = lam_lin(ku);
mu_u(ilt) = mu_lin(1:nlt);
mu_u(ibx) = mu_lin(nlt+ngt+(1:nbx));

Lambda = struct( ...
    'eqnonlin', lam(1:neqnln), ...
    'ineqnonlin', mu(1:niqnln), ...
    'mu_l', mu_l((nx+1):end), ...
    'mu_u', mu_u((nx+1):end), ...
    'lower', mu_l(1:nx), ...
    'upper', mu_u(1:nx) );

return;
