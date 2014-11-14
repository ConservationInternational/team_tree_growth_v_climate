data {
    int<lower=0> n_tree;
    int<lower=0> n_plot;
    int<lower=0> n_site;
    int<lower=0> n_genus;
    int<lower=0> n_B;
    int<lower=0> n_B_g;
    int<lower=0> n_period;
    int<lower=0> n_blocks;
    real<lower=0> sigma_obs_lower;
    int<lower=0> tree_ID[n_tree];
    int<lower=0> plot_ID[n_tree];
    int<lower=0> site_ID[n_tree];
    int<lower=0> genus_ID[n_tree];
    int<lower=0> t0[n_tree];
    int<lower=0> tf[n_tree];
    int<lower=0> n_miss;
    int<lower=0> n_obs;
    int<lower=0> obs_indices_tree[n_obs];
    int<lower=0> obs_indices_period[n_obs];
    int<lower=0> miss_indices_tree[n_miss];
    int<lower=0> miss_indices_period[n_miss];
    vector[n_obs] dbh_obs;
    vector[n_tree] WD;
    vector[n_tree] WD_sq;
    vector[n_tree] elev;
    vector[n_period + 1] temp[n_tree];
    vector[n_period + 1] precip[n_tree];
    vector[n_period + 1] precip_sq[n_tree];
}

parameters {
    matrix[n_tree, n_period + 1] dbh_latent;
    vector[n_miss] dbh_miss;
    vector[n_B] B;
    vector[n_B_T] B_T;
    matrix[n_B_g, n_genus] B_g_std;
    vector[n_B_g] gamma_B_g;
    cholesky_factor_corr[n_B_g] L_rho_B_g;
    vector<lower=0>[n_B_g] sigma_B_g_sigma;
    vector[n_tree] int_ijk_std;
    vector[n_plot] int_jk_std;
    vector[n_site] int_k_std;
    real<lower=sigma_obs_lower> sigma_obs;
    real<lower=0> sigma_proc;
    real<lower=0> sigma_int_ijk;
    real<lower=0> sigma_int_jk;
    real<lower=0> sigma_int_k;
}

transformed parameters {
    matrix[n_tree, n_period + 1] dbh;
    matrix[n_tree, n_period + 1] dbh_latent_sq;
    vector[n_tree] int_ijk;
    vector[n_plot] int_jk;
    vector[n_site] int_k;
    matrix[n_genus, n_B_g] B_g;

    // Handle missing data
    for (n in 1:n_miss) {
        dbh[miss_indices_tree[n], miss_indices_period[n]] <- dbh_miss[n];
    }

    for (n in 1:n_obs) {
        dbh[obs_indices_tree[n], obs_indices_period[n]] <- dbh_obs[n];
    }

    // Matt trick- see http://bit.ly/1qz4NC6
    int_ijk <- sigma_int_ijk * int_ijk_std; // int_ijk ~ normal(0, sigma_int_ijk)
    int_jk <- sigma_int_jk * int_jk_std; // int_jk ~ normal(0, sigma_int_jk)
    int_k <- sigma_int_k * int_k_std; // int_k ~ normal(0, sigma_int_k)

    B_g <- transpose(rep_matrix(gamma_B_g, n_genus) + diag_pre_multiply(sigma_B_g_sigma, L_rho_B_g) * B_g_std);

    // TODO: This could be made faster by not squaring cells that are no data
    for (i in 1:n_tree) {
        for (j in 1:(n_period+1)) {
            dbh_latent_sq[i][j] <- square(dbh_latent[i][j]);
        }
    }
}

model {
    int n_rows;

    //########################################################################
    // Fixed effects
    B ~ normal(0, 10);

    //########################################################################
    // Observation and process error
    sigma_obs ~ cauchy(0, 1);
    sigma_proc ~ cauchy(0, 1);

    //########################################################################
    // Nested random effects
    int_ijk_std ~ normal(0, 1); // Matt trick
    sigma_int_ijk ~ cauchy(0, 1);

    int_jk_std ~ normal(0, 1); // Matt trick
    sigma_int_jk ~ cauchy(0, 1);

    sigma_int_k ~ cauchy(0, 1);
    int_k_std ~ normal(0, 1); // Matt trick

    //########################################################################
    // Correlated random effects at genus level (crossed). Based on Gelman and 
    // Hill pg. 377-378, and http://bit.ly/1pADacO, and http://bit.ly/1pEpXjo
    
    # Priors for random coefficients:
    to_vector(B_g_std) ~ normal(0, 10); // implies: B_g ~ multi_normal(gamma_B_g, CovarianceMatrix);

    # Hyperpriors
    gamma_B_g ~ normal(0, 5);
    sigma_B_g_sigma ~ cauchy(0, 2.5);
    L_rho_B_g ~ lkj_corr_cholesky(3);

    //########################################################################
    // Model missing data. Need to do this explicitly in Stan.
    dbh_miss ~ normal(0, 10);

    # Specially handle first latent dbh
    block(dbh_latent, 1, 1, n_tree, 1) ~ normal(0, 10);

    //########################################################################
    // Main likelihood
    for (i in 1:n_blocks) {
        n_rows <- block_end_row[i] - block_start_row[i] + 1;
        { // block to allow local dbh_pred and ID vectors of varying size
            matrix[n_rows, block_n_periods[i]] dbh_pred;
            vector[n_rows] site_IDs;
            vector[n_rows] plot_IDs;
            vector[n_rows] tree_IDs;
            vector[n_rows] genus_IDs;

            tree_IDs <- segment(tree_ID, block_start_row[i], n_rows)
            plot_IDs <- plot_ID[tree_IDs];
            site_IDs <- site_ID[tree_IDs];
            genus_IDs <- genus_ID[tree_IDs];

            dbh_pred <- B[1] * WD[tree_IDs] +
                B[2] * WD_sq[tree_IDs] +
                int_ijk[tree_IDs] +
                int_jk[plot_IDs] +
                int_k[site_IDs] +
                B_g[genus_IDs, 1] +
                B_g[genus_IDs, 2] * block(precip, block_start_row[i], 1, block_end_row[i], block_n_periods[i]) +
                B_g[genus_IDs, 3] * block(precip_sq, block_start_row[i], 1, block_end_row[i], block_n_periods[i]) +
                B_g[genus_IDs, 4] * (B_T[site_IDs, 1] + B_T[site_IDs, 2] * block(temp, block_start_row[i], 1, block_end_row[i], block_n_periods[i]) + B_T[site_IDs, 3] * elev[plot_IDs]) +
                B_g[genus_IDs, 5] * square(B_T[site_IDs, 1] + B_T[site_IDs, 2] * block(temp, block_start_row[i], 1, block_end_row[i], block_n_periods[i]) + B_T[site_IDs, 3] * elev[plot_IDs]) +
                B_g[genus_IDs, 6] * block(dbh_latent, block_start_row[i], 1, block_end_row[i], block_n_periods[i]) +
                B_g[genus_IDs, 7] * block(dbh_latent_sq, block_start_row[i], 1, block_end_row[i], block_n_periods[i]);

            // Model dbh_latent
            block(dbh_latent, block_start_row[i], 1, block_end_row[i], block_n_periods[i]) ~ normal(dbh_pred, sigma_proc);
            //print("Predicted dbh: ", dbh_pred);
        }
        // Model dbh with mean equal to latent dbh
        block(dbh, block_start_row[i], 2, block_end_row[i], block_n_periods[i] - 1) ~ normal(block(dbh_latent, block_start_row[i], 2, block_end_row[i], block_n_periods[i] - 1), sigma_obs);
    }

    //########################################################################
    // Temperature model
    B_T ~ normal(0, 10);
}
