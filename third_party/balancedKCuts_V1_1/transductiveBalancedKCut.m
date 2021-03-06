function [clustering, bCut, clusters] = transductiveBalancedKCut(W, k, Labels, imbalance, vertexWeights, CheegerFlag, nInitializations, parForLoop, debugMode)
%
% transductiveBalancedKCut minimizes balanced k-cut subject to label constraints using the method described in  
% S. S. Rangapuram, P. K. Mudrakarta and M. Hein. 
% Tight Continuous relaxation of the Balanced k-Cut Problem. NIPS 2014.
% Cite the above paper if you are using this code.
%
% Usage: [clustering, bCut, clusters, bCuts] = transductiveBalancedKCut(W, k, Labels, imbalance, vertexWeights, nInitializations, parForLoop, debugMode)
%
% Inputs:
%   W:                  Symmetric (SPARSE) weight matrix with zero diagonal.
%   k:                  number of clusters.
%   Labels:             label matrix of size nVertices x k. Labels(i, j) =
%                       1 if the vertex i should belong to the class j
%
% Optional Inputs:
%   imbalance:          imbalance paramter. Defalut value = k-1; for
%                       Normalized/Ratio Cheeger cut, use imbalance = 1.
%   vertexWeights:      vector of all ones for all types of Ratio cuts; i.e., balancing function is based on cardinalities (this is the defualt setting),
%                       degree vector for Normalized cut; one can also pass any generic vertex weights (strictly positive) instead of degree. 
%   CheegerFlag:        1 for Cheeger Cuts, 0 for Normalized/Ratio cut.
%                       In the latter case, imbalance must be equal to 1.
%                       Default value = 1.
%   nInitializations:   number of starting points for the method (there will be an additional run using unconstrained solution as a starting point, so total runs = nInitializations+1). 
%                       Default value = 12.
%                       For large datasets this might take longer; in this case set nInitializations to any value between 1
%                       and 7 (possibly compromising on quality).
%   parForLoop:         uses matlab parfor loop to to start the method from
%                       different starting points in parallel (this is default setting).
%                       Set this to false, if you do not want to use parfor.
%   debugMode:          prints additional debugging messages. Default value = false
%
% Outputs:
%   clustering:         result vector with labels 1, ..., k
%   bCut:               the balanced cut value
%   clusters:           cluster indicator matrix of size nVertices x k
%
% Use,
%   clustering = transductiveBalancedKCut(W, k, Labels), for the asymmetric ratio Cheeger cut problem
%   clustering = transductiveBalancedKCut(W, k, Labels, 1), for the ratio Cheeger cut problem
%   clustering = transductiveBalancedKCut(W, k, Labels, 1, sum(W,2)), for the normalized Cheeger cut problem
%   clustering = transductiveBalancedKCut(W, k, Labels, 1, ones(size(W,1),1), 0), for the ratio cut problem
%   clustering = transductiveBalancedKCut(W, k, Labels, 1, sum(W,2), 0), for the normalized cut problem
%   clustering = transductiveBalancedKCut(W, k, Labels, k-1, sum(W,2)), for the asymmetric normalized Cheeger cut problem
%
% (C)2014-15 Syama Sundar Rangapuram, Pramod Kaushik Mudrakarta and Matthias Hein 
% Machine Learning Group, Saarland University, Saarbruecken, Germany
% http://www.ml.uni-saarland.de

    addpath('Ncut_9');
    addpath('GraphDemos/');    
    nVertices = size(W, 1);
    
    assert(sum(diag(W))==0, 'No self loops: diagonal of the weight matrix W must be zero.');
    assert(issparse(W) && isnumeric(W), 'The weight matrix W must be sparse and numeric');
    assert(issymmetric(W), 'The weight matrix W must be symmetric');
    assert(k >= 2, 'Wrong usage: number of clusters should at least be 2');
    if ~exist('imbalance', 'var'), imbalance = k-1; else assert(imbalance > 0, 'Wrong usgae: imbalance should be greater than zero'); end
    if ~exist('vertexWeights', 'var')
        vertexWeights = ones(nVertices, 1); 
    else
        assert(size(vertexWeights, 1) == nVertices & size(vertexWeights, 2) == 1, 'Wrong usgae: vertexWeights should be a vector of size nVertices x 1 (column vector)');
        assert(min(vertexWeights) > 0, 'Wrong usgae: vertexWeights should be strictly positive');
    end
    if ~exist('CheegerFlag', 'var'), CheegerFlag = 1; else assert(CheegerFlag == 1 || CheegerFlag ==0, 'CheegerFlag should either be zero or one'); end            
    if ~exist('nInitializations', 'var'), nInitializations = 12; else assert(nInitializations >= 1, 'Wrong usgae: number of starting points for the method should at least be 1'); end
    if ~exist('parForLoop', 'var'), parForLoop = true; end                
    if ~exist('debugMode', 'var'), debugMode = false; end            
    if ~exist('Labels', 'var'), Labels = sparse(nVertices, k); else assert(size(Labels,1) == nVertices & size(Labels,2) == k, 'Wrong usgae: the labels matrix should be nVertices x k'); end
        
    nSpecStarts = min(2, nInitializations);
    nDiffusedStarts = min(5, ceil(0.5*(nInitializations-2)));
    nLabelDiffusedStarts= max(0, nInitializations-nSpecStarts-nDiffusedStarts);
    
    nLabelsPerClass = sum(Labels);
    if max(nLabelsPerClass) > 1 % merge the labels belonging to the same class
        Y = zeros(nVertices, 1); % label vector; it takes values from 1:k
        labels = 1:k;
        [ixLabels, jxLabels] = find(Labels);
        Y(ixLabels) = labels(jxLabels);
        
        Worig = W; vertexWeightsOrig = vertexWeights; LabelsOrig = Labels; 
        [W, mapSparsify] = sparsify_vx(W, Y, debugMode);           
        W = 0.5*(W+W'); % sparsify might have introdued numerical errors in W.
        nVertices = size(W, 1);
        Labels = sparse(nVertices, k);
        Labels(mapSparsify, :) = LabelsOrig;        
        vertexWeights = sparse(mapSparsify, 1, vertexWeights, nVertices, 1);        
    end

    if imbalance > 1
        assert(CheegerFlag == 1, 'Wrong usage: imbalance must be 1 for non-Cheeger balanced cuts')
        minBalance = imbalance*min(vertexWeights);
        maxBalance = imbalance*sum(vertexWeights)/k;
    else
        minBalance = min(vertexWeights);
        maxBalance = sum(vertexWeights)/2;
    end
    
    % Compute unconstrained solution
    display('Computing unconstrained solution');
    [~, ~, clusters] = balancedKCut(W, k, imbalance, vertexWeights, 1, nSpecStarts+nDiffusedStarts, parForLoop, debugMode);
    
    % Compute constrained solution from the diffused label start    
    labelDiffusedClusters = getDiffusedStart(W,1,zeros(nVertices,k),1,Labels);   
    [cnstrClustering, cnstrCuts, cnstrClusters] = minimizeBCutMultiClass(W, vertexWeights, k, 1, imbalance, labelDiffusedClusters, 0, minBalance, maxBalance, 3200, 400, 0, Labels, debugMode);            
    
    if sum(nLabelsPerClass) > 0
        % Modify unconstrained solution such that it satisfies the transductive labeling
        clusters = getFeasibleClusters(W, vertexWeights, clusters, imbalance, Labels, debugMode);        
    end
    
    startingFs = zeros(nVertices, k, nLabelDiffusedStarts+1); %  one additional start using unconstrained solution
    counter = 1;    
    startingFs(:, :, counter) = clusters;    
    
    for diffusedStartIdx=1:nLabelDiffusedStarts
        counter = counter+1;
        startingFs(:, :, counter) = getDiffusedStart(W,round(nVertices*0.01/k),cnstrClusters,1,zeros(nVertices,k));            
    end
    
    nInitializations = nLabelDiffusedStarts+1;
    bCuts_all = zeros(k, nInitializations+1); % +1 for storing the already computed constrained clusters
    clusterings = zeros(nVertices, nInitializations+1);
    clusters_all = zeros(nVertices, k, nInitializations+1);
    clusterings(:, end) = cnstrClustering;
    clusters_all(:, :, end) = cnstrClusters; 
    bCuts_all(:, end) = cnstrCuts;
    
    if parForLoop && nInitializations <= 1
        parForLoop = false;
    end
    
    if parForLoop
        parfor i=1:nInitializations
            [clusterings(:, i), bCuts_all(:, i), clusters_all(:, :, i)] = minimizeBCutMultiClass(W, vertexWeights, k, 1, imbalance, startingFs(:, :, i), 0, minBalance, maxBalance, 3200, 400, 0, Labels, debugMode);                
            if ~CheegerFlag
                bCuts_all(:, i) = bCutMultiClass(W, clusterings(:, i), vertexWeights, 0, 1);
            end
            display(['Solution obtained with the initialization ' num2str(i) ': '  num2str(sum(bCuts_all(:, i)))]);
        end 
    else
        for i=1:nInitializations        
            [clusterings(:, i), bCuts_all(:, i), clusters_all(:, :, i)] = minimizeBCutMultiClass(W, vertexWeights, k, 1, imbalance, startingFs(:, :, i), 0, minBalance, maxBalance, 3200, 400, 0, Labels, debugMode);                
            if ~CheegerFlag
                bCuts_all(:, i) = bCutMultiClass(W, clusterings(:, i), vertexWeights, 0, 1);
            end
            display(['Solution obtained with the initialization ' num2str(i) ': '  num2str(sum(bCuts_all(:, i)))]);
        end
    end 
    
    bCuts = sum(bCuts_all);
    [bCut, minIx] = min(bCuts);
    clustering = clusterings(:, minIx);
    clusters = clusters_all(:, :, minIx);
    
    if max(nLabelsPerClass) > 1 % some of the labels were merged; recover the original clustering
        clustering = clustering(mapSparsify);
        clusters = clusters(mapSparsify, :);        
    end
    
    display(['************* Final solution (transductive setting): ' num2str(bCut) ' ******************']);
    
    if debugMode
        assert(length(unique(clustering))==k, 'clustering does not have k labels');        
        if max(nLabelsPerClass) > 1 % some of the labels were merged; recover the original data
            W = Worig; vertexWeights = vertexWeightsOrig; Labels = LabelsOrig;
        end
        assert(length(clustering)==size(W,1), 'clustering does not have n vertices');
        assert( abs(sum(bCutMultiClass(W, clustering, vertexWeights, CheegerFlag, imbalance)) - bCut) < 1e-8);
        [ix, jx] = find(Labels);
        assert(sum(clustering(ix) ~= jx) == 0, 'Labels constraints are not satisfied')
    end
    
end