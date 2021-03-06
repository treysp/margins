# function to get effect variances using specified vce method
get_effect_variances <- 
function(data, 
         model = model, 
         variables = NULL, # which mes do we need variances of
         type = c("response", "link", "terms"),
         vcov = stats::vcov(model),
         vce = c("delta", "simulation", "bootstrap", "none"),
         iterations = 50L, # if vce == "bootstrap" or "simulation"
         weights = NULL,
         eps = 1e-7,
         varslist = NULL,
         ...) {
    
    # march.arg() for arguments
    type <- match.arg(type)
    vce <- match.arg(vce)
    
    # setup vcov
    if (is.function(vcov)) {
        vcov <- vcov(model)
    }
    
    # identify classes of terms in `model`
    if (is.null(varslist)) {
        varslist <- find_terms_in_model(model, variables = variables)
    }
    
    # deploy appropriate vce procedure
    if (vce == "none") {
        
        return(list(variances = NULL, vcov = NULL, jacobian = NULL))
        
    } else if (vce == "delta") {
        
        # default method
        
        # express each marginal effect as a function of estimated coefficients
        # holding data constant (using `gradient_factory()`)
        # use `jacobian(gradient_factory(), model$coef)`
        # to get `jacobian`, an ME-by-beta matrix,
        # such that jacobian %*% V %*% t(jacobian)
        # gives the variance of each marginal effect
        # http://www.soderbom.net/lecture10notes.pdf
        # http://stats.stackexchange.com/questions/122066/how-to-use-delta-method-for-standard-errors-of-marginal-effects
        
        # build gradient function
        FUN <- gradient_factory(data = data,
                                model = model,
                                variables = variables,
                                type = type,
                                weights = weights,
                                eps = eps,
                                varslist = varslist,
                                ...)
        # get jacobian
        if (inherits(model, "merMod")) {
            requireNamespace("lme4")
            jacobian <- jacobian(FUN, lme4::fixef(model)[names(lme4::fixef(model)) %in% c("(Intercept)", colnames(vcov))], weights = weights, eps = eps)
            # sandwich
            vc <- as.matrix(jacobian %*% vcov %*% t(jacobian))
        } else {
            jacobian <- jacobian(FUN, coef(model)[names(coef(model)) %in% c("(Intercept)", colnames(vcov))], weights = weights, eps = eps)
            # sandwich
            vc <- jacobian %*% vcov %*% t(jacobian)
        }
        # extract variances from diagonal
        variances <- diag(vc)
        
    } else if (vce == "simulation") {
        
        # copy model for quick use in estimation
        tmpmodel <- model
        tmpmodel[["model"]] <- NULL # remove data from model for memory
        
        # simulate from multivariate normal
        coefmat <- MASS::mvrnorm(iterations, coef(model), vcov)
        
        # estimate AME from from each simulated coefficient vector
        effectmat <- apply(coefmat, 1, function(coefrow) {
            tmpmodel[["coefficients"]] <- coefrow
            if (is.null(weights)) {
                means <- colMeans(marginal_effects(model = tmpmodel, data = data, variables = variables, type = type, eps = eps, varslist = varslist, ...), na.rm = TRUE)
            } else {
                me_tmp <- marginal_effects(model = tmpmodel, data = data, variables = variables, type = type, eps = eps, varslist = varslist, ...)
                means <- unlist(stats::setNames(lapply(me_tmp, stats::weighted.mean, w = weights, na.rm = TRUE), names(me_tmp)))
            }
            if (!is.matrix(means)) {
                matrix(means, ncol = 1L)
            }
            return(means)
        })
        # calculate the variance of the simulated AMEs
        vc <- var(t(effectmat))
        variances <- diag(vc)
        jacobian <- NULL
        
    } else if (vce == "bootstrap") {
    
        # function to calculate AME for one bootstrap subsample
        bootfun <- function() {
            samp <- sample(seq_len(nrow(data)), nrow(data), TRUE)
            tmpmodel <- model
            tmpmodel[["call"]][["data"]] <- data[samp,]
            tmpmodel <- eval(tmpmodel[["call"]])
            if (is.null(weights)) {
                means <- colMeans(marginal_effects(model = tmpmodel,
                                                   data = data[samp,],
                                                   variables = variables,
                                                   type = type,
                                                   eps = eps,
                                                   varslist = varslist,
                                                   ...), na.rm = TRUE)
            } else {
                me_tmp <- marginal_effects(model = tmpmodel, data = data[samp,], variables = variables, type = type, eps = eps, varslist = varslist, ...)
                means <- unlist(stats::setNames(lapply(me_tmp, stats::weighted.mean, w = weights, na.rm = TRUE), names(me_tmp)))
            }
            means
        }
        # bootstrap the data and take the variance of bootstrapped AMEs
        vc <- var(t(replicate(iterations, bootfun())))
        variances <- diag(vc)
        jacobian <- NULL
    }
    
    # replicate to nrow(data)
    variances <- setNames(lapply(variances, rep, nrow(data)), paste0("Var_", names(variances)))
    
    return(list(variances = variances, vcov = vc, jacobian = jacobian))
}
