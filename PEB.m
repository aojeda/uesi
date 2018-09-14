classdef PEB < handle
    properties
        H
        Hi
        HiHit
        Ci
        Ut
        s2
        Ny
        Nx
        Ng
        Tx
        defaultOptions = struct(...
            'maxIter',100,...       % Maximum number of iterations
            'verbose',true,...      % Produce per-iteration prints
            'maxTol',1e-1,...       % Maximum tolerance of logE change
            'bufferSize',100,...    % History buffer size
            'gammaMin',1,...        % Minimum gamma allowed in the first stage  
            'doPruning','true',...  % Enable the pruning stage      
            'smoothLambda', true);
    end
    properties(GetAccess=private)
        Iy
        lambdaBuffer = nan(100,1);
    end
    
    methods
        function obj = PEB(H, Delta, blocks)
            obj.H = H;
            [obj.Ny,obj.Nx] = size(H);
            obj.Ng = size(blocks,2);
            
            obj.Hi    = cell(1,obj.Ng);
            obj.HiHit = zeros([obj.Ny, obj.Ny, obj.Ng]);
            obj.Ci    = sparse(obj.Nx^2,obj.Ng);
            sqCi      = cell(1,obj.Ng);
            ind       = zeros(obj.Nx,obj.Nx);
            obj.Iy    = speye(obj.Ny);
            
            for k=1:obj.Ng
                % Per-block square root precision matrix
                Di = Delta(blocks(:,k),blocks(:,k));
                
                % Per-block covariance matrix
                sqCi{k} = inv(Di);
                sqCi{k} = sqCi{k}/norm(sqCi{k},'fro');
                ind(blocks(:,k),blocks(:,k)) = 1;
                Citmp = sqCi{k}*sqCi{k}';
                obj.Ci(ind==1,k) = Citmp(:);
                ind(blocks(:,k),blocks(:,k)) = 0;
                
                % Per-block standardized gain matrices
                obj.Hi{k} = obj.H(:,blocks(:,k))*sqCi{k};
                obj.HiHit(:,:,k) = obj.Hi{k}*obj.Hi{k}';
            end
            
            % Unweighted prior covariance
            C = reshape(sum(obj.Ci,2),[obj.Nx, obj.Nx]);
                
            % Fix possible 0 diagonal elements
            dc = diag(C);
            dc(dc==0) = median(dc(dc~=0));
            C = C - diag(diag(C)) + diag(dc);
            
            % Compute svd
            sqC = chol(C);
            [U,s] = svd(obj.H*sqC,'econ');
            obj.s2 = diag(s).^2;
            obj.Ut = U';
        end
        
        %%
        function [lambda, gamma, gamma_F, history] = learning(obj,Y,lambda0, gamma0,options)
            if nargin < 4
                [lambda0, gamma0] = initHyperparameters(obj, Y);
            end
            if nargin < 5
                options = obj.defaultOptions;
            end
            if ~isfield(options,'doPruning')
                options.doPruning = true;
            end
            [lambda, gamma, gamma_F, history] = optimizeFullModel(obj,Y,lambda0, gamma0, options);
            if options.doPruning
                [gamma,history] = pruning(obj,Y,lambda,gamma,history,options);
            end
            Sx = obj.Ci*gamma;
            Sx = sparse(reshape(Sx,obj.Nx,obj.Nx));
            [~, iSy] = obj.calculateModelCov(lambda,gamma);
            obj.Tx = Sx*obj.H'*iSy;
        end
        
        %%
        function x = inference(obj, y)
            x = obj.Tx*y;
        end
        
        %%
        function [X,lambda, gamma_F, gamma, logE] = update(obj,Y,lambda0,gamma0,options)
            if nargin < 4
                lambda0 = []; 
                gamma0 = [];
            end
            if isempty(lambda0) && isempty(gamma0)
                [lambda0, gamma0] = initHyperparameters(obj, Y);
            elseif ~isempty(lambda0) && isempty(gamma0)
                [~, gamma0] = initHyperparameters(obj, Y);
            end
            if nargin < 5
                options = obj.defaultOptions;
            end
            [lambda, gamma, gamma_F, history] = learning(obj,Y,lambda0, gamma0,options);
            X = inference(obj, Y);
            logE = history.logE(history.pointer);
        end
    end
    methods(Access=private)
        %%
        function [lambda0, gamma0] = initHyperparameters(obj, Y)
            UtY2 = (obj.Ut*Y).^2;
            S = [obj.s2 obj.s2*0+1];
            phi = abs(mean((S'*S)\(S'*UtY2),2));
            gamma0  = phi(1);
            lambda0 = phi(2);
        end
        %%
        function [lambda, gamma, gamma_F, history] = optimizeFullModel(obj,Y,lambda0, gamma0, options)
            UtY2 = (obj.Ut*Y).^2;
            Nt = size(Y,2);
            Cy = Y*Y'/Nt;
            gamma = ones(obj.Ng,1);
            lambda = lambda0;
            gamma_F = gamma0;
            gamma(:) = gamma_F;
            
            history = struct('lambda',nan(options.bufferSize,1),'gamma_F',nan(options.bufferSize,1),'logE',nan(options.bufferSize,1),'pointer',1);
            history.lambda(1)  = lambda;
            history.gamma_F(1) = gamma_F;
            history.logE(1)    = calculateLogEvidence(obj,Cy,lambda,gamma);
            
            for k=2:options.maxIter
                psi = gamma_F*obj.s2+lambda;
                psi2 = psi.^2;
                
                lambda   = lambda *sum(mean(bsxfun(@times,UtY2,     1./psi2),2))/(eps+sum(     1./psi));
                gamma_F  = gamma_F*sum(mean(bsxfun(@times,UtY2,obj.s2./psi2),2))/(eps+sum(obj.s2./psi));
                gamma_F(gamma_F<options.gammaMin) = options.gammaMin;
                gamma(:) = gamma_F;
                
                history.logE(k) = calculateLogEvidence(obj,Cy,lambda,gamma);
                
                if options.verbose
                    fprintf('%i => diff(logE): %.4g   logE: %.5g   Lambda: %.4g   Gamma: %.4g\n',...
                        k,abs(diff(fliplr(history.logE(k-1:k)))),history.logE(k),lambda,gamma_F);
                end
                
                % Check convergence and exit condition
                if diff(history.logE(k-1:k)) < options.maxTol, break;end
            end
            history.pointer = k;
            if options.smoothLambda
                obj.lambdaBuffer = circshift(obj.lambdaBuffer,-1);
                obj.lambdaBuffer(end) = lambda;
                lambda = mean(obj.lambdaBuffer(~isnan(obj.lambdaBuffer)));
                obj.lambdaBuffer(end) = lambda;
            end
        end

        %%
        function [gamma,history] = pruning(obj,Y,lambda,gamma,history,options)
            Nt = size(Y,2);
            Cy = Y*Y'/Nt;
            for k=1:options.maxIter
                [~, iSy] = obj.calculateModelCov(lambda,gamma);
                num = gamma;
                den = num;
                for i=1:obj.Ng
                    Hi_iSy = obj.Hi{i}'*iSy;
                    num(i) = norm(Hi_iSy*Y,'fro');
                    den(i) = sqrt(abs(sum(sum((Hi_iSy)'.*obj.Hi{i}))));
                end
                gamma = (gamma/sqrt(Nt)).*num./(den+eps);
                history.pointer = history.pointer+1;
                history.logE(history.pointer) = calculateLogEvidence(obj,Cy,lambda,gamma);
                if options.verbose
                    fprintf('%i => diff(logE): %.4g   logE: %.5g   Sum Gamma: %.4g\n',history.pointer,diff(...
                        history.logE(history.pointer-1:history.pointer)),history.logE(history.pointer),sum(nonzeros(gamma)));
                end
                if diff(history.logE(history.pointer-1:history.pointer)) < options.maxTol, break;end
            end
        end
        
        %%
        function logE = calculateLogEvidence(obj,Cy,lambda,gamma)
            [Sy, iSy] = calculateModelCov(obj,lambda,gamma);
            logE = (-1/2)*(trace(Cy*iSy) + PEB.logDet(Sy));
        end
        
        %%
        function [Sy, iSy] = calculateModelCov(obj,lambda,gamma, indices)
            if nargin < 4, indices = 1:obj.Ng;end
            gHHt = sum(bsxfun(@times, obj.HiHit(:,:,indices),permute(gamma(indices),[3 2 1])),3);
            Sy = lambda*obj.Iy+gHHt;
            try
                iSy = invChol_mex(double(Sy));
            catch ME
                warning(ME.message)
                if strcmp(ME.identifier,'MATLAB:invChol_mex:dpotrf:notposdef')
                    warning('Possibly the data is rank deficient!')
                end
                [Utmp,S,Vtmp] = svd(Sy);
                stmp = real(diag(S));
                invS = 1./stmp;
                invS(isinf(invS)) = 0;
                iSy = Utmp*diag(invS)*Vtmp';
            end
        end
    end
    methods(Static)
        %%
        function log_d = logDet(S)
            log_d = log(det(S));     
            if isinf(log_d)
                e = eig(S);
                e(e<0) = eps;
                log_d = sum(log(e));
            end
        end
    end
end
