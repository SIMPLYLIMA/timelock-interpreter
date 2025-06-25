;; timelock-escrow.clar
;; A flexible smart contract for creating time-locked escrow and asset management on the Stacks blockchain.
;; The contract provides secure, programmable mechanisms for locking and releasing assets
;; based on predefined time constraints and conditions. It supports complex escrow scenarios,
;; scheduled fund distributions, and conditional asset transfers with precise time-based controls.

;; -----------------
;; Error Constants
;; -----------------

(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-COLLECTION-NOT-FOUND (err u101))
(define-constant ERR-COLLECTION-CLOSED (err u102))
(define-constant ERR-COLLECTION-LIMIT-REACHED (err u103))
(define-constant ERR-INVALID-PARAMETERS (err u104))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u105))
(define-constant ERR-NFT-NOT-FOUND (err u106))
(define-constant ERR-NOT-OWNER (err u107))
(define-constant ERR-SALE-NOT-ACTIVE (err u108))
(define-constant ERR-COLLECTION-EXISTS (err u109))
(define-constant ERR-INVALID-ROYALTY (err u110))
(define-constant ERR-LISTING-EXISTS (err u111))
(define-constant ERR-LISTING-NOT-FOUND (err u112))

;; -----------------
;; SFT Definition
;; -----------------

;; Define the lattice NFT as a semi-fungible token (SFT) where each collection has a unique token-id
(define-non-fungible-token lattice-nft 
  {collection-id: uint, token-index: uint})

;; -----------------
;; Data Storage
;; -----------------

;; Admin address to manage platform functions
(define-data-var contract-admin principal tx-sender)

;; Platform fee percentage (in basis points, e.g. 250 = 2.5%)
(define-data-var platform-fee-bps uint u250)

;; Total collections created
(define-data-var last-collection-id uint u0)

;; Collection information
(define-map collections
  uint
  {
    creator: principal,
    name: (string-ascii 64),
    description: (string-ascii 256),
    max-supply: uint,
    current-supply: uint,
    mint-price: uint,
    royalty-bps: uint,  ;; Creator royalty in basis points
    is-open: bool,      ;; Whether minting is currently allowed
    created-at: uint,   ;; Block height of creation
    metadata-uri: (string-ascii 256)  ;; URI for collection metadata
  }
)

;; Lattice Parameters defines the mathematical properties of the lattice
(define-map lattice-parameters
  uint  ;; collection-id
  {
    dimensions: uint,           ;; Number of dimensions (2D, 3D, etc.)
    nodes: uint,                ;; Number of nodes in the lattice
    connections: (list 128 {from: uint, to: uint, weight: uint}),  ;; Node connections
    color-scheme: (string-ascii 64),   ;; Base color scheme
    transformations: (list 10 (string-ascii 32)),  ;; Mathematical transformations
    additional-params: (list 20 {key: (string-ascii 32), value: (string-ascii 64)})  ;; Additional parameters
  }
)

;; Individual NFT data within a collection
(define-map nfts
  {collection-id: uint, token-index: uint}
  {
    owner: principal,
    seed: uint,        ;; Unique seed value that determines the specific pattern
    minted-at: uint,   ;; Block height when minted
    metadata-uri: (string-ascii 256)  ;; URI for NFT-specific metadata
  }
)

;; NFTs owned by each principal
(define-map principal-nfts
  principal
  (list 1000 {collection-id: uint, token-index: uint})
)

;; Marketplace listings
(define-map listings
  {collection-id: uint, token-index: uint}
  {
    seller: principal,
    price: uint,
    listed-at: uint  ;; Block height when listed
  }
)

;; -----------------
;; Private Functions
;; -----------------

;; Get current NFTs owned by a principal
(define-private (get-principal-nfts (owner principal))
  (default-to (list) (map-get? principal-nfts owner))
)


;; Calculate platform fee amount
(define-private (calculate-platform-fee (amount uint))
  (/ (* amount (var-get platform-fee-bps)) u10000)
)

;; Calculate royalty amount
(define-private (calculate-royalty (amount uint) (royalty-bps uint))
  (/ (* amount royalty-bps) u10000)
)

;; Transfer STX with royalty split
(define-private (transfer-stx-with-royalty (amount uint) (seller principal) (creator principal) (royalty-bps uint))
  (let (
    (platform-fee (calculate-platform-fee amount))
    (royalty-amount (calculate-royalty amount royalty-bps))
    (seller-amount (- amount (+ platform-fee royalty-amount)))
    (contract-admin-addr (var-get contract-admin))
  )
    (try! (stx-transfer? platform-fee tx-sender contract-admin-addr))
    (try! (stx-transfer? royalty-amount tx-sender creator))
    (try! (stx-transfer? seller-amount tx-sender seller))
    (ok true)
  )
)

;; Check if the caller is the contract admin
(define-private (is-contract-admin)
  (is-eq tx-sender (var-get contract-admin))
)

;; -----------------
;; Read-only Functions
;; -----------------

;; Get collection information
(define-read-only (get-collection (collection-id uint))
  (map-get? collections collection-id)
)

;; Get collection lattice parameters
(define-read-only (get-lattice-parameters (collection-id uint))
  (map-get? lattice-parameters collection-id)
)

;; Get NFT details
(define-read-only (get-nft (collection-id uint) (token-index uint))
  (map-get? nfts {collection-id: collection-id, token-index: token-index})
)

;; Get NFT owner
(define-read-only (get-nft-owner (collection-id uint) (token-index uint))
  (match (map-get? nfts {collection-id: collection-id, token-index: token-index})
    nft-data (some (get owner nft-data))
    none
  )
)

;; Get marketplace listing
(define-read-only (get-listing (collection-id uint) (token-index uint))
  (map-get? listings {collection-id: collection-id, token-index: token-index})
)

;; Get all NFTs owned by a principal
(define-read-only (get-owned-nfts (owner principal))
  (get-principal-nfts owner)
)

;; Get the total count of collections
(define-read-only (get-collections-count)
  (var-get last-collection-id)
)

;; -----------------
;; Public Functions
;; -----------------

;; Create a new lattice collection
(define-public (create-collection 
  (name (string-ascii 64))
  (description (string-ascii 256))
  (max-supply uint)
  (mint-price uint)
  (royalty-bps uint)
  (metadata-uri (string-ascii 256))
  (dimensions uint)
  (nodes uint)
  (connections (list 128 {from: uint, to: uint, weight: uint}))
  (color-scheme (string-ascii 64))
  (transformations (list 10 (string-ascii 32)))
  (additional-params (list 20 {key: (string-ascii 32), value: (string-ascii 64)}))
)
  (let (
    (new-collection-id (+ (var-get last-collection-id) u1))
  )
    ;; Validate inputs
    (asserts! (> max-supply u0) ERR-INVALID-PARAMETERS)
    (asserts! (<= royalty-bps u3000) ERR-INVALID-ROYALTY) ;; Max 30% royalty
    (asserts! (>= dimensions u1) ERR-INVALID-PARAMETERS)
    (asserts! (>= nodes u2) ERR-INVALID-PARAMETERS)
    
    ;; Update collection count
    (var-set last-collection-id new-collection-id)
    
    ;; Create collection
    (map-set collections
      new-collection-id
      {
        creator: tx-sender,
        name: name,
        description: description,
        max-supply: max-supply,
        current-supply: u0,
        mint-price: mint-price,
        royalty-bps: royalty-bps,
        is-open: true,
        created-at: block-height,
        metadata-uri: metadata-uri
      }
    )
    
    ;; Set lattice parameters
    (map-set lattice-parameters
      new-collection-id
      {
        dimensions: dimensions,
        nodes: nodes,
        connections: connections,
        color-scheme: color-scheme,
        transformations: transformations,
        additional-params: additional-params
      }
    )
    
    (ok new-collection-id)
  )
)

;; List NFT for sale
(define-public (list-nft-for-sale (collection-id uint) (token-index uint) (price uint))
  (let (
    (nft-id {collection-id: collection-id, token-index: token-index})
    (nft-data (unwrap! (map-get? nfts nft-id) ERR-NFT-NOT-FOUND))
  )
    ;; Verify ownership
    (asserts! (is-eq (get owner nft-data) tx-sender) ERR-NOT-OWNER)
    
    ;; Ensure price is valid
    (asserts! (> price u0) ERR-INVALID-PARAMETERS)
    
    ;; Check if already listed
    (asserts! (is-none (map-get? listings nft-id)) ERR-LISTING-EXISTS)
    
    ;; Create listing
    (map-set listings
      nft-id
      {
        seller: tx-sender,
        price: price,
        listed-at: block-height
      }
    )
    
    (ok true)
  )
)

;; Cancel NFT listing
(define-public (cancel-listing (collection-id uint) (token-index uint))
  (let (
    (nft-id {collection-id: collection-id, token-index: token-index})
    (listing (unwrap! (map-get? listings nft-id) ERR-LISTING-NOT-FOUND))
  )
    ;; Verify ownership
    (asserts! (is-eq (get seller listing) tx-sender) ERR-NOT-AUTHORIZED)
    
    ;; Remove listing
    (map-delete listings nft-id)
    
    (ok true)
  )
)

;; Close or open a collection for minting
(define-public (set-collection-status (collection-id uint) (is-open bool))
  (let (
    (collection (unwrap! (map-get? collections collection-id) ERR-COLLECTION-NOT-FOUND))
  )
    ;; Verify caller is the collection creator
    (asserts! (is-eq (get creator collection) tx-sender) ERR-NOT-AUTHORIZED)
    
    ;; Update collection status
    (map-set collections
      collection-id
      (merge collection {is-open: is-open})
    )
    
    (ok true)
  )
)

;; Update platform fee (admin only)
(define-public (set-platform-fee (new-fee-bps uint))
  (begin
    ;; Verify caller is admin
    (asserts! (is-contract-admin) ERR-NOT-AUTHORIZED)
    
    ;; Ensure fee is reasonable (max 10%)
    (asserts! (<= new-fee-bps u1000) ERR-INVALID-PARAMETERS)
    
    ;; Update fee
    (var-set platform-fee-bps new-fee-bps)
    
    (ok true)
  )
)

;; Transfer contract admin role (admin only)
(define-public (set-contract-admin (new-admin principal))
  (begin
    ;; Verify caller is current admin
    (asserts! (is-contract-admin) ERR-NOT-AUTHORIZED)
    
    ;; Update admin
    (var-set contract-admin new-admin)
    
    (ok true)
  )
)