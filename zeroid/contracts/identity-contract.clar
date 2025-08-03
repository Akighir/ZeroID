;; NFT-Based Identity Contract
;; Each identity is represented as a unique NFT with advanced features

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-ALREADY-EXISTS (err u102))
(define-constant ERR-NOT-OWNER (err u103))
(define-constant ERR-INVALID-AMOUNT (err u104))
(define-constant ERR-REPUTATION-LOCKED (err u105))
(define-constant ERR-IDENTITY-SUSPENDED (err u106))
(define-constant ERR-INVALID-SIGNATURE (err u107))
(define-constant ERR-EXPIRED-PROOF (err u108))
(define-constant ERR-INSUFFICIENT-REPUTATION (err u109))
(define-constant ERR-RATE-LIMITED (err u110))

;; Constants
(define-constant CONTRACT-NAME "identity-nft")
(define-constant INITIAL-REPUTATION u100)
(define-constant MIN-REPUTATION u0)
(define-constant MAX-REPUTATION u1000)
(define-constant REPUTATION-DECAY-BLOCKS u52560) ;; ~1 year in blocks
(define-constant PROOF-EXPIRY-BLOCKS u10080) ;; ~1 week in blocks
(define-constant RATE-LIMIT-BLOCKS u144) ;; ~1 day in blocks

;; NFT implementation
(define-non-fungible-token identity-nft uint)

;; Data vars
(define-data-var last-token-id uint u0)
(define-data-var contract-owner principal tx-sender)
(define-data-var contract-paused bool false)
(define-data-var mint-fee uint u1000000) ;; 1 STX in microSTX
(define-data-var total-identities uint u0)
(define-data-var verification-fee uint u500000) ;; 0.5 STX

;; Maps
(define-map token-to-owner uint principal)
(define-map owner-to-token principal uint)

(define-map identity-metadata
    uint
    {
        did: (string-ascii 256),
        reputation: uint,
        created-at: uint,
        verified: bool,
        suspended: bool,
        last-activity: uint,
        reputation-locked-until: uint,
        metadata-uri: (optional (string-ascii 256)),
        verification-level: uint, ;; 0-5 verification levels
        social-recovery-enabled: bool
    }
)

(define-map cross-chain-proofs
    { token-id: uint, chain-id: uint }
    {
        external-address: (string-ascii 128),
        proof-method: (string-ascii 50),
        verified: bool,
        timestamp: uint,
        expires-at: uint,
        signature: (optional (buff 65)),
        verifier: (optional principal)
    }
)

(define-map reputation-history
    { token-id: uint, block-height: uint }
    {
        old-reputation: uint,
        new-reputation: uint,
        reason: (string-ascii 128),
        verifier: principal
    }
)

(define-map authorized-verifiers principal bool)
(define-map verifier-stats
    principal
    {
        verifications-performed: uint,
        reputation-score: uint,
        active-since: uint
    }
)

(define-map social-recovery
    uint
    {
        recovery-addresses: (list 5 principal),
        required-confirmations: uint,
        active-recovery: bool,
        recovery-initiated-at: uint
    }
)

(define-map pending-recoveries
    { token-id: uint, recovery-principal: principal }
    {
        new-owner: principal,
        confirmations: uint,
        confirmed-by: (list 5 principal),
        expires-at: uint
    }
)

(define-map user-activity
    principal
    {
        last-action: uint,
        action-count: uint,
        reputation-earned: uint,
        verifications-received: uint
    }
)

(define-map rate-limits
    { user: principal, action: (string-ascii 32) }
    uint ;; last action block
)

;; Events (using print for event logging)
(define-private (emit-event (event-type (string-ascii 32)) (data (string-ascii 256)))
    (print { event: event-type, data: data, block: block-height })
)

;; SIP-009 NFT Standard Functions
(define-read-only (get-last-token-id)
    (ok (var-get last-token-id))
)

(define-read-only (get-token-uri (token-id uint))
    (match (map-get? identity-metadata token-id)
        metadata (ok (get metadata-uri metadata))
        (err ERR-NOT-FOUND)
    )
)

(define-read-only (get-owner (token-id uint))
    (ok (nft-get-owner? identity-nft token-id))
)

(define-public (transfer (token-id uint) (sender principal) (recipient principal))
    (begin
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq tx-sender sender) ERR-NOT-AUTHORIZED)
        (asserts! (is-some (nft-get-owner? identity-nft token-id)) ERR-NOT-FOUND)
        
        ;; Check if identity is suspended
        (let ((metadata (unwrap! (map-get? identity-metadata token-id) ERR-NOT-FOUND)))
            (asserts! (not (get suspended metadata)) ERR-IDENTITY-SUSPENDED)
        )
        
        ;; Perform transfer
        (try! (nft-transfer? identity-nft token-id sender recipient))
        (map-set token-to-owner token-id recipient)
        (map-delete owner-to-token sender)
        (map-set owner-to-token recipient token-id)
        
        ;; Update activity and emit event
        (let ((activity-result (update-user-activity recipient "transfer")))
            ;; Emit event
            (emit-event "transfer" (concat "token-" (int-to-ascii token-id)))
            
            (ok true)
        )
    )
)

;; Identity Functions
(define-public (mint-identity 
    (recipient principal) 
    (did (string-ascii 256)) 
    (metadata-uri (optional (string-ascii 256)))
    (social-recovery-addresses (list 5 principal)))
    (let ((new-token-id (+ (var-get last-token-id) u1)))
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (is-none (map-get? owner-to-token recipient)) ERR-ALREADY-EXISTS)
        (asserts! (>= (stx-get-balance tx-sender) (var-get mint-fee)) ERR-INVALID-AMOUNT)
        
        ;; Check rate limiting
        (try! (check-rate-limit tx-sender "mint"))
        
        ;; Transfer mint fee to contract
        (try! (stx-transfer? (var-get mint-fee) tx-sender (as-contract tx-sender)))
        
        ;; Mint NFT
        (try! (nft-mint? identity-nft new-token-id recipient))
        (map-set token-to-owner new-token-id recipient)
        (map-set owner-to-token recipient new-token-id)
        
        ;; Set identity metadata
        (map-set identity-metadata new-token-id {
            did: did,
            reputation: INITIAL-REPUTATION,
            created-at: block-height,
            verified: false,
            suspended: false,
            last-activity: block-height,
            reputation-locked-until: u0,
            metadata-uri: metadata-uri,
            verification-level: u0,
            social-recovery-enabled: (> (len social-recovery-addresses) u0)
        })
        
        ;; Set up social recovery if addresses provided
        (if (> (len social-recovery-addresses) u0)
            (map-set social-recovery new-token-id {
                recovery-addresses: social-recovery-addresses,
                required-confirmations: (/ (len social-recovery-addresses) u2),
                active-recovery: false,
                recovery-initiated-at: u0
            })
            true
        )
        
        ;; Update counters and activity
        (var-set last-token-id new-token-id)
        (var-set total-identities (+ (var-get total-identities) u1))
        (let ((activity-result (update-user-activity recipient "mint")))
            ;; Emit event
            (emit-event "mint" (concat "token-" (int-to-ascii new-token-id)))
            
            (ok new-token-id)
        )
    )
)

(define-public (add-cross-chain-proof 
    (chain-id uint) 
    (external-address (string-ascii 128)) 
    (proof-method (string-ascii 50))
    (signature (optional (buff 65))))
    (let ((token-id (unwrap! (map-get? owner-to-token tx-sender) ERR-NOT-FOUND)))
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        
        ;; Check rate limiting
        (try! (check-rate-limit tx-sender "add-proof"))
        
        ;; Check if identity is suspended
        (let ((metadata (unwrap! (map-get? identity-metadata token-id) ERR-NOT-FOUND)))
            (asserts! (not (get suspended metadata)) ERR-IDENTITY-SUSPENDED)
        )
        
        (map-set cross-chain-proofs
            { token-id: token-id, chain-id: chain-id }
            {
                external-address: external-address,
                proof-method: proof-method,
                verified: false,
                timestamp: block-height,
                expires-at: (+ block-height PROOF-EXPIRY-BLOCKS),
                signature: signature,
                verifier: none
            }
        )
        
        ;; Update activity and emit event
        (let ((activity-result (update-user-activity tx-sender "add-proof")))
            ;; Emit event
            (emit-event "proof-added" (concat "chain-" (int-to-ascii chain-id)))
            
            (ok true)
        )
    )
)

(define-public (verify-cross-chain-proof (token-id uint) (chain-id uint))
    (begin
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (or (is-eq tx-sender (var-get contract-owner)) 
                     (default-to false (map-get? authorized-verifiers tx-sender))) ERR-NOT-AUTHORIZED)
        
        (let ((proof (unwrap! (map-get? cross-chain-proofs { token-id: token-id, chain-id: chain-id }) ERR-NOT-FOUND)))
            ;; Check if proof hasn't expired
            (asserts! (< block-height (get expires-at proof)) ERR-EXPIRED-PROOF)
            
            ;; Update proof as verified
            (map-set cross-chain-proofs
                { token-id: token-id, chain-id: chain-id }
                (merge proof { verified: true, verifier: (some tx-sender) })
            )
            
            ;; Update verifier stats
            (update-verifier-stats tx-sender)
            
            ;; Increase reputation for verified proof
            (try! (adjust-reputation token-id u10 "cross-chain-verification"))
            
            ;; Emit event
            (emit-event "proof-verified" (concat "token-" (int-to-ascii token-id)))
            
            (ok true)
        )
    )
)

(define-public (update-reputation (token-id uint) (new-reputation uint) (reason (string-ascii 128)))
    (begin
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (or (is-eq tx-sender (var-get contract-owner)) 
                     (default-to false (map-get? authorized-verifiers tx-sender))) ERR-NOT-AUTHORIZED)
        (asserts! (and (>= new-reputation MIN-REPUTATION) (<= new-reputation MAX-REPUTATION)) ERR-INVALID-AMOUNT)
        
        (let ((metadata (unwrap! (map-get? identity-metadata token-id) ERR-NOT-FOUND)))
            ;; Check if reputation is locked
            (asserts! (> block-height (get reputation-locked-until metadata)) ERR-REPUTATION-LOCKED)
            
            ;; Store reputation history
            (map-set reputation-history
                { token-id: token-id, block-height: block-height }
                {
                    old-reputation: (get reputation metadata),
                    new-reputation: new-reputation,
                    reason: reason,
                    verifier: tx-sender
                }
            )
            
            ;; Update metadata
            (map-set identity-metadata token-id
                (merge metadata { 
                    reputation: new-reputation,
                    last-activity: block-height
                })
            )
            
            ;; Update verifier stats
            (update-verifier-stats tx-sender)
            
            ;; Emit event
            (emit-event "reputation-updated" (concat "token-" (int-to-ascii token-id)))
            
            (ok true)
        )
    )
)

(define-public (suspend-identity (token-id uint) (reason (string-ascii 128)))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        
        (let ((metadata (unwrap! (map-get? identity-metadata token-id) ERR-NOT-FOUND)))
            (map-set identity-metadata token-id
                (merge metadata { suspended: true })
            )
            
            ;; Emit event
            (emit-event "identity-suspended" (concat "token-" (int-to-ascii token-id)))
            
            (ok true)
        )
    )
)

(define-public (unsuspend-identity (token-id uint))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        
        (let ((metadata (unwrap! (map-get? identity-metadata token-id) ERR-NOT-FOUND)))
            (map-set identity-metadata token-id
                (merge metadata { suspended: false })
            )
            
            ;; Emit event
            (emit-event "identity-unsuspended" (concat "token-" (int-to-ascii token-id)))
            
            (ok true)
        )
    )
)

(define-public (initiate-social-recovery (token-id uint) (new-owner principal))
    (let ((owner (unwrap! (nft-get-owner? identity-nft token-id) ERR-NOT-FOUND))
          (recovery-data (unwrap! (map-get? social-recovery token-id) ERR-NOT-FOUND)))
        
        ;; Check if caller is in recovery addresses
        (asserts! (is-some (index-of (get recovery-addresses recovery-data) tx-sender)) ERR-NOT-AUTHORIZED)
        (asserts! (get social-recovery-enabled (unwrap! (map-get? identity-metadata token-id) ERR-NOT-FOUND)) ERR-NOT-AUTHORIZED)
        
        ;; Create pending recovery
        (map-set pending-recoveries
            { token-id: token-id, recovery-principal: tx-sender }
            {
                new-owner: new-owner,
                confirmations: u1,
                confirmed-by: (list tx-sender),
                expires-at: (+ block-height PROOF-EXPIRY-BLOCKS)
            }
        )
        
        ;; Emit event
        (emit-event "recovery-initiated" (concat "token-" (int-to-ascii token-id)))
        
        (ok true)
    )
)

;; Private helper functions
(define-private (check-rate-limit (user principal) (action (string-ascii 32)))
    (let ((last-action (default-to u0 (map-get? rate-limits { user: user, action: action }))))
        (if (< (- block-height last-action) RATE-LIMIT-BLOCKS)
            ERR-RATE-LIMITED
            (begin
                (map-set rate-limits { user: user, action: action } block-height)
                (ok true)
            )
        )
    )
)

(define-private (update-user-activity (user principal) (action (string-ascii 32)))
    (let ((activity (default-to { last-action: u0, action-count: u0, reputation-earned: u0, verifications-received: u0 }
                                (map-get? user-activity user))))
        (map-set user-activity user
            (merge activity {
                last-action: block-height,
                action-count: (+ (get action-count activity) u1)
            })
        )
        (ok true)
    )
)

(define-private (update-verifier-stats (verifier principal))
    (let ((stats (default-to { verifications-performed: u0, reputation-score: u100, active-since: block-height }
                            (map-get? verifier-stats verifier))))
        (map-set verifier-stats verifier
            (merge stats {
                verifications-performed: (+ (get verifications-performed stats) u1)
            })
        )
    )
)

(define-private (adjust-reputation (token-id uint) (adjustment uint) (reason (string-ascii 128)))
    (let ((metadata (unwrap! (map-get? identity-metadata token-id) ERR-NOT-FOUND))
          (current-rep (get reputation metadata))
          (new-rep (if (> (+ current-rep adjustment) MAX-REPUTATION) 
                      MAX-REPUTATION 
                      (+ current-rep adjustment))))
        
        ;; Store reputation history
        (map-set reputation-history
            { token-id: token-id, block-height: block-height }
            {
                old-reputation: current-rep,
                new-reputation: new-rep,
                reason: reason,
                verifier: tx-sender
            }
        )
        
        ;; Update reputation
        (map-set identity-metadata token-id
            (merge metadata { reputation: new-rep })
        )
        
        (ok true)
    )
)

;; Admin functions
(define-public (add-authorized-verifier (verifier principal))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (map-set authorized-verifiers verifier true)
        (ok true)
    )
)

(define-public (remove-authorized-verifier (verifier principal))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (map-delete authorized-verifiers verifier)
        (ok true)
    )
)

(define-public (set-contract-paused (paused bool))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (var-set contract-paused paused)
        (ok true)
    )
)

(define-public (set-mint-fee (new-fee uint))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (var-set mint-fee new-fee)
        (ok true)
    )
)

;; Read functions
(define-read-only (get-identity-by-owner (owner principal))
    (match (map-get? owner-to-token owner)
        token-id (map-get? identity-metadata token-id)
        none
    )
)

(define-read-only (get-identity-metadata (token-id uint))
    (map-get? identity-metadata token-id)
)

(define-read-only (get-cross-chain-proof (token-id uint) (chain-id uint))
    (map-get? cross-chain-proofs { token-id: token-id, chain-id: chain-id })
)

(define-read-only (get-reputation-history (token-id uint) (block-height uint))
    (map-get? reputation-history { token-id: token-id, block-height: block-height })
)

(define-read-only (get-user-activity (user principal))
    (map-get? user-activity user)
)

(define-read-only (get-verifier-stats (verifier principal))
    (map-get? verifier-stats verifier)
)

(define-read-only (get-contract-stats)
    (ok {
        total-identities: (var-get total-identities),
        last-token-id: (var-get last-token-id),
        mint-fee: (var-get mint-fee),
        contract-paused: (var-get contract-paused)
    })
)

(define-read-only (is-authorized-verifier (verifier principal))
    (default-to false (map-get? authorized-verifiers verifier))
)