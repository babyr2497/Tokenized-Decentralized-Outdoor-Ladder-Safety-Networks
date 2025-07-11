;; Height Assessment Contract
;; Matches ladder size to specific project requirements

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_INVALID_PROJECT (err u201))
(define-constant ERR_INVALID_HEIGHT (err u202))
(define-constant ERR_UNSAFE_CONFIGURATION (err u203))
(define-constant ERR_NOT_FOUND (err u204))

;; Data Variables
(define-data-var next-assessment-id uint u1)
(define-data-var next-project-id uint u1)

;; Data Maps
(define-map project-requirements uint {
    owner: principal,
    project-name: (string-ascii 100),
    required-height: uint,
    work-duration: uint,
    load-requirements: uint,
    surface-type: (string-ascii 30),
    safety-margin: uint,
    created-at: uint,
    is-active: bool
})

(define-map height-assessments uint {
    project-id: uint,
    assessor: principal,
    recommended-ladder-type: (string-ascii 50),
    min-ladder-height: uint,
    max-safe-height: uint,
    load-capacity-needed: uint,
    safety-rating: uint,
    assessment-notes: (string-ascii 200),
    assessed-at: uint,
    is-approved: bool
})

(define-map ladder-specifications (string-ascii 50) {
    max-height: uint,
    weight-capacity: uint,
    base-width: uint,
    safety-rating: uint,
    recommended-uses: (string-ascii 100)
})

;; Initialize ladder specifications
(map-set ladder-specifications "step-ladder-6ft" {
    max-height: u72, ;; 6 feet in inches
    weight-capacity: u250,
    base-width: u24,
    safety-rating: u85,
    recommended-uses: "indoor-light-work"
})

(map-set ladder-specifications "extension-ladder-20ft" {
    max-height: u240, ;; 20 feet in inches
    weight-capacity: u300,
    base-width: u18,
    safety-rating: u90,
    recommended-uses: "outdoor-medium-work"
})

(map-set ladder-specifications "extension-ladder-32ft" {
    max-height: u384, ;; 32 feet in inches
    weight-capacity: u375,
    base-width: u20,
    safety-rating: u95,
    recommended-uses: "outdoor-heavy-work"
})

;; Public Functions

;; Create a new project with height requirements
(define-public (create-project (project-name (string-ascii 100)) (required-height uint) (work-duration uint) (load-requirements uint) (surface-type (string-ascii 30)))
    (let ((project-id (var-get next-project-id)))
        (asserts! (> required-height u0) ERR_INVALID_HEIGHT)
        (asserts! (> work-duration u0) ERR_INVALID_PROJECT)

        (map-set project-requirements project-id {
            owner: tx-sender,
            project-name: project-name,
            required-height: required-height,
            work-duration: work-duration,
            load-requirements: load-requirements,
            surface-type: surface-type,
            safety-margin: u20, ;; 20% safety margin
            created-at: block-height,
            is-active: true
        })

        (var-set next-project-id (+ project-id u1))
        (print {event: "project-created", project-id: project-id, owner: tx-sender})
        (ok project-id)
    )
)

;; Perform height assessment for a project
(define-public (assess-height-requirements (project-id uint))
    (let (
        (project (unwrap! (map-get? project-requirements project-id) ERR_INVALID_PROJECT))
        (assessment-id (var-get next-assessment-id))
        (assessment-result (calculate-height-assessment project))
    )
        (asserts! (get is-active project) ERR_INVALID_PROJECT)

        (map-set height-assessments assessment-id {
            project-id: project-id,
            assessor: tx-sender,
            recommended-ladder-type: (get recommended-type assessment-result),
            min-ladder-height: (get min-height assessment-result),
            max-safe-height: (get max-height assessment-result),
            load-capacity-needed: (get load-capacity assessment-result),
            safety-rating: (get safety-rating assessment-result),
            assessment-notes: (get notes assessment-result),
            assessed-at: block-height,
            is-approved: (get is-safe assessment-result)
        })

        (var-set next-assessment-id (+ assessment-id u1))
        (print {event: "height-assessed", assessment-id: assessment-id, project-id: project-id, is-approved: (get is-safe assessment-result)})
        (ok assessment-id)
    )
)

;; Update project requirements
(define-public (update-project (project-id uint) (required-height uint) (load-requirements uint))
    (let ((project (unwrap! (map-get? project-requirements project-id) ERR_INVALID_PROJECT)))
        (asserts! (is-eq tx-sender (get owner project)) ERR_UNAUTHORIZED)
        (asserts! (> required-height u0) ERR_INVALID_HEIGHT)

        (map-set project-requirements project-id
            (merge project {
                required-height: required-height,
                load-requirements: load-requirements
            }))

        (print {event: "project-updated", project-id: project-id})
        (ok true)
    )
)

;; Approve or reject assessment
(define-public (update-assessment-approval (assessment-id uint) (is-approved bool))
    (let ((assessment (unwrap! (map-get? height-assessments assessment-id) ERR_NOT_FOUND)))
        (asserts! (or (is-eq tx-sender (get assessor assessment)) (is-eq tx-sender CONTRACT_OWNER)) ERR_UNAUTHORIZED)

        (map-set height-assessments assessment-id
            (merge assessment {is-approved: is-approved}))

        (print {event: "assessment-approval-updated", assessment-id: assessment-id, is-approved: is-approved})
        (ok true)
    )
)

;; Read-only Functions

;; Get project details
(define-read-only (get-project (project-id uint))
    (map-get? project-requirements project-id)
)

;; Get assessment details
(define-read-only (get-assessment (assessment-id uint))
    (map-get? height-assessments assessment-id)
)

;; Get ladder specifications
(define-read-only (get-ladder-specs (ladder-type (string-ascii 50)))
    (map-get? ladder-specifications ladder-type)
)

;; Check if height is safe for ladder type
(define-read-only (is-height-safe (ladder-type (string-ascii 50)) (required-height uint))
    (match (map-get? ladder-specifications ladder-type)
        specs (>= (get max-height specs) required-height)
        false
    )
)

;; Get recommended ladder for height
(define-read-only (get-recommended-ladder (required-height uint) (load-requirements uint))
    (if (<= required-height u72)
        (some "step-ladder-6ft")
        (if (<= required-height u240)
            (some "extension-ladder-20ft")
            (if (<= required-height u384)
                (some "extension-ladder-32ft")
                none
            )
        )
    )
)

;; Private Functions

;; Calculate comprehensive height assessment
(define-private (calculate-height-assessment (project {owner: principal, project-name: (string-ascii 100), required-height: uint, work-duration: uint, load-requirements: uint, surface-type: (string-ascii 30), safety-margin: uint, created-at: uint, is-active: bool}))
    (let (
        (required-height (get required-height project))
        (load-requirements (get load-requirements project))
        (safety-margin (get safety-margin project))
        (adjusted-height (+ required-height (/ (* required-height safety-margin) u100)))
        (recommended-type (unwrap-panic (get-recommended-ladder adjusted-height load-requirements)))
        (ladder-specs (unwrap-panic (map-get? ladder-specifications recommended-type)))
    )
        {
            recommended-type: recommended-type,
            min-height: required-height,
            max-height: (get max-height ladder-specs),
            load-capacity: (get weight-capacity ladder-specs),
            safety-rating: (get safety-rating ladder-specs),
            notes: "Assessment based on project requirements and safety standards",
            is-safe: (and
                (>= (get max-height ladder-specs) adjusted-height)
                (>= (get weight-capacity ladder-specs) load-requirements)
            )
        }
    )
)
