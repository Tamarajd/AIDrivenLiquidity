;; AI-Driven Liquidity Incentive Model
;; This smart contract implements an AI-driven liquidity incentive system that rewards
;; liquidity providers based on multiple factors including liquidity depth, duration,
;; volatility contribution, and AI-predicted market conditions. The contract uses
;; weighted scoring mechanisms to distribute rewards fairly and efficiently.

;; constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-insufficient-balance (err u102))
(define-constant err-invalid-amount (err u103))
(define-constant err-already-exists (err u104))
(define-constant err-pool-inactive (err u105))
(define-constant err-unauthorized (err u106))
(define-constant err-invalid-parameters (err u107))

;; Reward calculation constants
(define-constant base-reward-rate u1000) ;; Base reward per block (in micro-tokens)
(define-constant max-multiplier u300) ;; Maximum 3x multiplier (300%)
(define-constant min-liquidity-threshold u1000000) ;; Minimum liquidity to earn rewards

;; data maps and vars

;; Tracks liquidity pools with their current state
(define-map liquidity-pools
    { pool-id: uint }
    {
        total-liquidity: uint,
        active: bool,
        reward-pool: uint,
        creation-block: uint,
        ai-risk-score: uint, ;; 0-100, lower is better
        volatility-index: uint ;; 0-100, measures price stability
    }
)

;; Tracks individual liquidity provider positions
(define-map provider-positions
    { provider: principal, pool-id: uint }
    {
        liquidity-amount: uint,
        entry-block: uint,
        last-claim-block: uint,
        accumulated-rewards: uint,
        loyalty-score: uint ;; Increases with time, 0-100
    }
)

;; AI model parameters for reward calculation
(define-map ai-model-weights
    { parameter-name: (string-ascii 50) }
    { weight: uint } ;; Weight in basis points (0-10000)
)

;; Tracks historical performance metrics for AI analysis
(define-map pool-metrics
    { pool-id: uint, metric-type: (string-ascii 30) }
    { value: uint, last-updated: uint }
)

;; Global state variables
(define-data-var total-pools uint u0)
(define-data-var total-rewards-distributed uint u0)
(define-data-var ai-oracle principal tx-sender) ;; Address authorized to update AI scores
(define-data-var emergency-pause bool false)

;; private functions

;; Helper function to get minimum of two uints
(define-private (min (a uint) (b uint))
    (if (<= a b) a b)
)

;; Helper function to get maximum of two uints
(define-private (max (a uint) (b uint))
    (if (>= a b) a b)
)

;; Calculate time-based loyalty multiplier (0-100)
(define-private (calculate-loyalty-score (entry-block uint) (current-block uint))
    (let
        (
            (blocks-staked (- current-block entry-block))
            (loyalty-score (/ (* blocks-staked u100) u144000)) ;; ~100 days to max loyalty
        )
        (if (> loyalty-score u100) u100 loyalty-score)
    )
)

;; Calculate liquidity depth multiplier based on pool size
(define-private (calculate-depth-multiplier (provider-liquidity uint) (total-liquidity uint))
    (if (is-eq total-liquidity u0)
        u0
        (let
            (
                (share-percentage (/ (* provider-liquidity u10000) total-liquidity))
            )
            ;; Larger providers get slightly better rates (up to 150%)
            (+ u100 (/ share-percentage u100))
        )
    )
)

;; Calculate AI-adjusted risk multiplier
(define-private (calculate-ai-risk-multiplier (ai-risk-score uint) (volatility-index uint))
    (let
        (
            (risk-factor (- u100 ai-risk-score)) ;; Invert: lower risk = higher multiplier
            (stability-factor (- u100 volatility-index))
            (combined-score (/ (+ risk-factor stability-factor) u2))
        )
        ;; Returns 50-150% based on AI assessment
        (+ u50 combined-score)
    )
)

;; Compute total reward multiplier from all factors
(define-private (compute-total-multiplier 
    (loyalty uint) 
    (depth uint) 
    (ai-risk uint))
    (let
        (
            (combined (/ (+ loyalty depth ai-risk) u3))
        )
        (if (> combined max-multiplier) max-multiplier combined)
    )
)

;; Validate pool exists and is active
(define-private (validate-pool-active (pool-id uint))
    (match (map-get? liquidity-pools { pool-id: pool-id })
        pool (ok (get active pool))
        err-not-found
    )
)

;; public functions

;; Initialize AI model weights for reward calculation
(define-public (initialize-ai-weights)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (map-set ai-model-weights { parameter-name: "liquidity-depth" } { weight: u3000 })
        (map-set ai-model-weights { parameter-name: "time-loyalty" } { weight: u2500 })
        (map-set ai-model-weights { parameter-name: "volatility-control" } { weight: u2000 })
        (map-set ai-model-weights { parameter-name: "ai-risk-assessment" } { weight: u2500 })
        (ok true)
    )
)

;; Create a new liquidity pool
(define-public (create-pool (pool-id uint) (initial-reward-pool uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (is-none (map-get? liquidity-pools { pool-id: pool-id })) err-already-exists)
        (asserts! (> initial-reward-pool u0) err-invalid-amount)
        
        (map-set liquidity-pools
            { pool-id: pool-id }
            {
                total-liquidity: u0,
                active: true,
                reward-pool: initial-reward-pool,
                creation-block: block-height,
                ai-risk-score: u50, ;; Neutral starting score
                volatility-index: u50
            }
        )
        (var-set total-pools (+ (var-get total-pools) u1))
        (ok pool-id)
    )
)

;; Add liquidity to a pool
(define-public (add-liquidity (pool-id uint) (amount uint))
    (let
        (
            (pool (unwrap! (map-get? liquidity-pools { pool-id: pool-id }) err-not-found))
            (existing-position (map-get? provider-positions { provider: tx-sender, pool-id: pool-id }))
        )
        (asserts! (not (var-get emergency-pause)) err-pool-inactive)
        (asserts! (get active pool) err-pool-inactive)
        (asserts! (> amount u0) err-invalid-amount)
        
        ;; Update pool total liquidity
        (map-set liquidity-pools
            { pool-id: pool-id }
            (merge pool { total-liquidity: (+ (get total-liquidity pool) amount) })
        )
        
        ;; Update or create provider position
        (match existing-position
            position
            (map-set provider-positions
                { provider: tx-sender, pool-id: pool-id }
                (merge position { 
                    liquidity-amount: (+ (get liquidity-amount position) amount),
                    loyalty-score: (calculate-loyalty-score (get entry-block position) block-height)
                })
            )
            (map-set provider-positions
                { provider: tx-sender, pool-id: pool-id }
                {
                    liquidity-amount: amount,
                    entry-block: block-height,
                    last-claim-block: block-height,
                    accumulated-rewards: u0,
                    loyalty-score: u0
                }
            )
        )
        (ok true)
    )
)

;; Update AI-driven risk scores (only callable by AI oracle)
(define-public (update-ai-scores (pool-id uint) (risk-score uint) (volatility uint))
    (let
        (
            (pool (unwrap! (map-get? liquidity-pools { pool-id: pool-id }) err-not-found))
        )
        (asserts! (is-eq tx-sender (var-get ai-oracle)) err-unauthorized)
        (asserts! (<= risk-score u100) err-invalid-parameters)
        (asserts! (<= volatility u100) err-invalid-parameters)
        
        (map-set liquidity-pools
            { pool-id: pool-id }
            (merge pool { 
                ai-risk-score: risk-score,
                volatility-index: volatility
            })
        )
        
        ;; Store historical metrics
        (map-set pool-metrics
            { pool-id: pool-id, metric-type: "risk-score" }
            { value: risk-score, last-updated: block-height }
        )
        (map-set pool-metrics
            { pool-id: pool-id, metric-type: "volatility" }
            { value: volatility, last-updated: block-height }
        )
        (ok true)
    )
)

;; Calculate pending rewards for a provider
(define-public (calculate-pending-rewards (provider principal) (pool-id uint))
    (let
        (
            (pool (unwrap! (map-get? liquidity-pools { pool-id: pool-id }) err-not-found))
            (position (unwrap! (map-get? provider-positions { provider: provider, pool-id: pool-id }) err-not-found))
            (blocks-elapsed (- block-height (get last-claim-block position)))
            (loyalty-multiplier (calculate-loyalty-score (get entry-block position) block-height))
            (depth-multiplier (calculate-depth-multiplier 
                (get liquidity-amount position) 
                (get total-liquidity pool)))
            (ai-multiplier (calculate-ai-risk-multiplier 
                (get ai-risk-score pool) 
                (get volatility-index pool)))
            (total-multiplier (compute-total-multiplier loyalty-multiplier depth-multiplier ai-multiplier))
            (base-rewards (* blocks-elapsed base-reward-rate))
            (adjusted-rewards (/ (* base-rewards total-multiplier) u100))
        )
        (ok adjusted-rewards)
    )
)

;; Claim accumulated rewards
(define-public (claim-rewards (pool-id uint))
    (let
        (
            (pool (unwrap! (map-get? liquidity-pools { pool-id: pool-id }) err-not-found))
            (position (unwrap! (map-get? provider-positions { provider: tx-sender, pool-id: pool-id }) err-not-found))
            (pending-rewards (unwrap! (calculate-pending-rewards tx-sender pool-id) err-not-found))
        )
        (asserts! (not (var-get emergency-pause)) err-pool-inactive)
        (asserts! (get active pool) err-pool-inactive)
        (asserts! (>= (get reward-pool pool) pending-rewards) err-insufficient-balance)
        (asserts! (>= (get liquidity-amount position) min-liquidity-threshold) err-invalid-amount)
        
        ;; Update pool reward balance
        (map-set liquidity-pools
            { pool-id: pool-id }
            (merge pool { reward-pool: (- (get reward-pool pool) pending-rewards) })
        )
        
        ;; Update provider position
        (map-set provider-positions
            { provider: tx-sender, pool-id: pool-id }
            (merge position {
                last-claim-block: block-height,
                accumulated-rewards: (+ (get accumulated-rewards position) pending-rewards),
                loyalty-score: (calculate-loyalty-score (get entry-block position) block-height)
            })
        )
        
        ;; Update global statistics
        (var-set total-rewards-distributed (+ (var-get total-rewards-distributed) pending-rewards))
        (ok pending-rewards)
    )
)


