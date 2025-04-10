# Program: MNE_replication.R
# Developed by: Bonnie Shook-Sa
# Last Updated: 12.17.24

library(plyr)
library(geex)
library(resample)
library(dplyr)

###### Bring in NHANES data and add indicator for those 2-7
nhanes <- read.csv("nhanes.csv")
nhanes$agelt8 <- ifelse(nhanes$age<8, 1, 0)


##########################################################
##### Complete case analysis, mean SPB
##########################################################

#first, limit to complete cases
nhanes.cc <- subset(nhanes, (!is.na(nhanes[,'sbp'])))

# Estimate weighted mean with corresponding standard error using M-estimation (geex package)
estfun_cc <- function(data){
  W <- data$sample_weight
  Y <- data$sbp

  function(theta){
      c(W*(Y-theta[1]))
  }
}

cc.res<-m_estimate(
  estFUN = estfun_cc,
  data = nhanes.cc,
  root_control = setup_root_control(start = c(0)))

#format output and compute CIs
cc.est <- cc.res@estimates
cc.se <- as.numeric(sqrt(cc.res@vcov))
cc.est.all <- as.data.frame(cbind(cc.est,cc.se))
names(cc.est.all) <- c('est','se')
cc.est.all$LCL <- as.numeric(cc.est.all$est)-1.96*as.numeric(cc.est.all$se)
cc.est.all$UCL <- as.numeric(cc.est.all$est)+1.96*as.numeric(cc.est.all$se)
cc.est.all$type <- "Complete Case"


##########################################################
##### Extrapolation, mean SPB
##########################################################

#first, fit model predicting SBP based on age group
stat.model <- glm(sbp ~ miss*age, data=nhanes, weights=sample_weight)

#extrapolate predictions to those missing sbp
nhanes.miss <- subset(nhanes, (is.na(nhanes[,'sbp'])))
nhanes.miss$miss <- 0
nhanes.miss$sbp <- predict(stat.model,nhanes.miss, type="response")
#note: warning about rank-deficient fit is expected because of inclusion of missing indicator in the model

#combine with complete case data to estimate the weighted mean
nhanes.extrap <- rbind(nhanes.cc, nhanes.miss)
nhanes.extrap.mean <- sum(nhanes.extrap$sbp * nhanes.extrap$sample_weight) / sum(nhanes.extrap$sample_weight)

#estimate the variance using M-estimation (geex package)
estfun_extrap <- function(data, models){
  W <- data$sample_weight
  M <- data$miss
  Y <- data$sbp

  #fit outcome model (by missingness variable, so we can later limit to complete case)
  Xmat <- grab_design_matrix(data=data, rhs_formula=grab_fixed_formula(models$out))
  out_scores <- grab_psiFUN(models$out, data)
  out_pos <- 1:ncol(Xmat)

  #create a design matrix for model predictions, where everyone has a non-missing indicator (so that they get imputed)
  data2 <- data
  data2$miss <- 0
  Xmat.imp <- grab_design_matrix(data=data2, rhs_formula=grab_fixed_formula(models$out))

  function(theta){
      p <- length(theta)
      #get predicted values from model for everyone
      pred.sbp <- Xmat.imp %*% theta[out_pos]
      #keep observed Y if not missing, imputed Y if missing
      Y.imp <- ifelse(M==0,Y,pred.sbp)

      #estimating equations
      c(W*out_scores(theta[out_pos]),
        W*(Y.imp-theta[p]))
  }
}

#function to call M-estimator
geex_extrap <- function(data, out_formula){
  out_model  <- glm(out_formula, data=data)
  models <- list(out=out_model)

  geex_results_extrap <- m_estimate(
    estFUN = estfun_extrap,
    data = data,
    root_control = setup_root_control(start=c(coef(out_model), nhanes.extrap.mean)),
    outer_args = list(models = models))
  return(geex_results_extrap)
}

#to avoid missing values in dataset, set all missing values to 999 (these will get replaced with imputed values during estimation)
nhanes.hold <- nhanes
nhanes.hold$sbp <- ifelse(nhanes$miss==1, 999, nhanes$sbp)

#run the M-estimation code to get standard error
extrap.res <- geex_extrap(nhanes.hold, sbp ~ miss*age)

#format output and compute CIs
extrap.est <- extrap.res@estimates[length(extrap.res@estimates)]
extrap.se <- as.numeric(sqrt(extrap.res@vcov[length(extrap.res@estimates),length(extrap.res@estimates)]))
extrap.est.all <- as.data.frame(cbind(extrap.est,extrap.se))
names(extrap.est.all) <- c('est','se')
extrap.est.all$LCL <- as.numeric(extrap.est.all$est) - 1.96*as.numeric(extrap.est.all$se)
extrap.est.all$UCL <- as.numeric(extrap.est.all$est) + 1.96*as.numeric(extrap.est.all$se)
extrap.est.all$type <- "Extrapolated"


##########################################################
##### Synthesis, mean SPB
##########################################################

### bring in data for mathematical model for children 2-7
height.params <- read.csv("height_params.csv")
sbp_params <- read.csv("sbp_params.csv")
sbp_params <- within(sbp_params, rm("code"))

#first, add height cutoffs to the dataset
nhanes$gender <- ifelse(nhanes$female==1, 'f', 'm')
nhanes2 <- join(nhanes, height.params, by=c("gender", "age"))
nhanes2$height <- nhanes2$height / 2.54
nhanes2$height_cat <- ifelse(nhanes2$height<nhanes2$c1,
                             1,
                             ifelse(nhanes2$height<nhanes2$c2,
                                    2,
                                    ifelse(nhanes2$height<nhanes2$c3,
                                           3,
                                           ifelse(nhanes2$height<nhanes2$c4,
                                                  4,
                                                  ifelse(nhanes2$height<nhanes2$c5,
                                                         5,
                                                         ifelse(nhanes2$height<nhanes2$c6,
                                                                6, 7))))))

#add on median and p90 sbps based on age, gender, and height category
nhanes3 <- join(nhanes2, sbp_params, by=c("gender", "age", "height_cat"))
nhanes3$norm_mean <- nhanes3$median
nhanes3$norm_sd <- (nhanes3$p90 - nhanes3$norm_mean) / qnorm(0.9)

### bootstrap function, from which we will derive point estimate and 95% CIs
bootstrap_syn <- function(B, bootdata){
  if(B == 0) return(0)
  if(B>0){
    boot.est <- matrix(NaN, nrow=B, ncol=1)
    datbi <- samp.bootstrap(nrow(bootdata), B)
    for(i in 1:B){
      dati <- bootdata[datbi[,i],]

      # split data into positive and nonpositive
      positive<-dati[dati$agelt8==0,]
      npositive<-dati[dati$agelt8==1,]

      # Fit outcome model for positive region, use it to impute those missing in positive region
      out.model  <- glm(sbp ~ miss*as.factor(age), data=positive)
      positive.miss <- subset(positive, (is.na(positive[,'sbp'])))
      positive.miss$miss <- 0
      positive.miss$sbp <- predict(out.model,positive.miss, type="response")
      positive.nmiss <- subset(positive, (!is.na(positive[,'sbp'])))
      positive.all <- rbind(positive.nmiss, positive.miss)

      #get a random draw from mathematical model for nonpositive region
      npositive$sbp <- rnorm(nrow(npositive), mean=npositive$norm_mean, sd=npositive$norm_sd)

      #combine
      allimputed <- rbind(positive.all,npositive)

      #store weighted mean
      boot.est [i] <- sum(allimputed$sbp * allimputed$sample_weight) / sum(allimputed$sample_weight)
    }
    return(boot.est)
  }
}

#run the function with 20000 bootstraps
syn.boots <- bootstrap_syn(20000, nhanes3)

#format output and compute CIs
syn.est <- median(syn.boots)
syn.LCL <- (quantile(syn.boots, probs=0.025, na.rm=FALSE))
syn.UCL <- (quantile(syn.boots, probs=0.975, na.rm=FALSE))
syn.all <- as.data.frame(cbind(syn.est, syn.LCL, syn.UCL))
syn.all$type <- "Synthesis"
syn.all$se <- NA
names(syn.all) <- c('est', 'LCL', 'UCL', 'type', 'se')


##########################################################
##### Combine and output all estimates
##########################################################
all.ests <- rbind(cc.est.all, extrap.est.all, syn.all)
write.csv(all.ests, "mean_sbp.csv")
