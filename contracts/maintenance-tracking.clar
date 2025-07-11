;; Maintenance Tracking Contract
;; Handles ladder inspection and repair scheduling

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u400))
(define-constant ERR_INVALID_LADDER (err u401))
(define-constant ERR_INVALID_MAINTENANCE (err u402))
(define-constant ERR_NOT_FOUND (err u403))
(define-constant ERR_ALREADY_SCHEDULED (err u404))

;; Data Variables
(define-data-var next-maintenance-id uint u1)
(define-data-var next-inspection-id uint u1)
(define-data-var maintenance-interval uint u4320) ;; 30 days in blocks

;; Data Maps
(define-map ladder-maintenance-records uint {
    ladder-id: uint,
    owner: principal,
    last-inspection: uint,
    next-inspection-due: uint,
    maintenance-score: uint,
    total-inspections: uint,
    total-repairs: uint,
    is-certified: bool,
    certification-expires: uint
})

(define-map maintenance-schedules uint {
    ladder-id: uint,
    scheduled-by: principal,
    maintenance-type: (string-ascii 30), ;; inspection, repair, certification
    scheduled-date: uint,
    assigned-technician: (optional principal),
    priority: (string-ascii 10), ;; low, medium, high, urgent
    status: (string-ascii 20), ;; scheduled, in-progress, completed, cancelled
    estimated-cost: uint,
    created-at: uint
})

(define-map inspection-reports uint {
    maintenance-id: uint,
    inspector: principal,
    inspection-date: uint,
    safety-rating: uint,
    structural-integrity: uint,
    wear-level: uint,
    defects-found: (list 5 (string-ascii 50)),
    recommendations: (string-ascii 200),
    next-inspection-date: uint,
    certification-status: bool
})

(define-map certified-technicians principal {
    name: (string-ascii 50),
    certification-level: uint,
    specializations: (list 3 (string-ascii 30)),
    total-inspections: uint,
    rating: uint,
    is-active: bool,
    certified-since: uint
})

;; Public Functions

;; Register ladder for maintenance tracking
(define-public (register-ladder-maintenance (ladder-id uint))
    (let ((maintenance-record-id ladder-id))
        (asserts! (is-none (map-get? ladder-maintenance-records maintenance-record-id)) ERR_ALREADY_SCHEDULED)

        (map-set ladder-maintenance-records maintenance-record-id {
            ladder-id: ladder-id,
            owner: tx-sender,
            last-inspection: block-height,
            next-inspection-due: (+ block-height (var-get maintenance-interval)),
            maintenance-score: u100,
            total-inspections: u0,
            total-repairs: u0,
            is-certified: false,
            certification-expires: u0
        })

        (print {event: "maintenance-registered", ladder-id: ladder-id, owner: tx-sender})
        (ok maintenance-record-id)
    )
)

;; Schedule maintenance
(define-public (schedule-maintenance (ladder-id uint) (maintenance-type (string-ascii 30)) (scheduled-date uint) (priority (string-ascii 10)))
    (let (
        (maintenance-id (var-get next-maintenance-id))
        (maintenance-record (unwrap! (map-get? ladder-maintenance-records ladder-id) ERR_INVALID_LADDER))
    )
        (asserts! (is-eq tx-sender (get owner maintenance-record)) ERR_UNAUTHORIZED)
        (asserts! (> scheduled-date block-height) ERR_INVALID_MAINTENANCE)

        (map-set maintenance-schedules maintenance-id {
            ladder-id: ladder-id,
            scheduled-by: tx-sender,
            maintenance-type: maintenance-type,
            scheduled-date: scheduled-date,
            assigned-technician: none,
            priority: priority,
            status: "scheduled",
            estimated-cost: (calculate-maintenance-cost maintenance-type priority),
            created-at: block-height
        })

        (var-set next-maintenance-id (+ maintenance-id u1))
        (print {event: "maintenance-scheduled", maintenance-id: maintenance-id, ladder-id: ladder-id, type: maintenance-type})
        (ok maintenance-id)
    )
)

;; Assign technician to maintenance
(define-public (assign-technician (maintenance-id uint) (technician principal))
    (let ((maintenance (unwrap! (map-get? maintenance-schedules maintenance-id) ERR_NOT_FOUND)))
        (asserts! (or (is-eq tx-sender (get scheduled-by maintenance)) (is-eq tx-sender CONTRACT_OWNER)) ERR_UNAUTHORIZED)
        (asserts! (is-some (map-get? certified-technicians technician)) ERR_UNAUTHORIZED)

        (map-set maintenance-schedules maintenance-id
            (merge maintenance {assigned-technician: (some technician)}))

        (print {event: "technician-assigned", maintenance-id: maintenance-id, technician: technician})
        (ok true)
    )
)

;; Complete inspection and create report
(define-public (complete-inspection (maintenance-id uint) (safety-rating uint) (structural-integrity uint) (wear-level uint) (defects (list 5 (string-ascii 50))) (recommendations (string-ascii 200)))
    (let (
        (maintenance (unwrap! (map-get? maintenance-schedules maintenance-id) ERR_NOT_FOUND))
        (inspection-id (var-get next-inspection-id))
        (technician-info (unwrap! (map-get? certified-technicians tx-sender) ERR_UNAUTHORIZED))
    )
        (asserts! (is-eq (some tx-sender) (get assigned-technician maintenance)) ERR_UNAUTHORIZED)
        (asserts! (is-eq (get maintenance-type maintenance) "inspection") ERR_INVALID_MAINTENANCE)
        (asserts! (and (<= safety-rating u100) (<= structural-integrity u100) (<= wear-level u100)) ERR_INVALID_MAINTENANCE)

        ;; Create inspection report
        (map-set inspection-reports inspection-id {
            maintenance-id: maintenance-id,
            inspector: tx-sender,
            inspection-date: block-height,
            safety-rating: safety-rating,
            structural-integrity: structural-integrity,
            wear-level: wear-level,
            defects-found: defects,
            recommendations: recommendations,
            next-inspection-date: (+ block-height (var-get maintenance-interval)),
            certification-status: (>= (calculate-overall-score safety-rating structural-integrity wear-level) u80)
        })

        ;; Update maintenance schedule
        (map-set maintenance-schedules maintenance-id
            (merge maintenance {status: "completed"}))

        ;; Update ladder maintenance record
        (let ((maintenance-record (unwrap! (map-get? ladder-maintenance-records (get ladder-id maintenance)) ERR_INVALID_LADDER)))
            (map-set ladder-maintenance-records (get ladder-id maintenance)
                (merge maintenance-record {
                    last-inspection: block-height,
                    next-inspection-due: (+ block-height (var-get maintenance-interval)),
                    maintenance-score: (calculate-overall-score safety-rating structural-integrity wear-level),
                    total-inspections: (+ (get total-inspections maintenance-record) u1),
                    is-certified: (>= (calculate-overall-score safety-rating structural-integrity wear-level) u80),
                    certification-expires: (if (>= (calculate-overall-score safety-rating structural-integrity wear-level) u80)
                        (+ block-height (* (var-get maintenance-interval) u12)) ;; 1 year
                        u0
                    )
                }))
        )

        ;; Update technician stats
        (map-set certified-technicians tx-sender
            (merge technician-info {total-inspections: (+ (get total-inspections technician-info) u1)}))

        (var-set next-inspection-id (+ inspection-id u1))
        (print {event: "inspection-completed", inspection-id: inspection-id, maintenance-id: maintenance-id, overall-score: (calculate-overall-score safety-rating structural-integrity wear-level)})
        (ok inspection-id)
    )
)

;; Register as certified technician
(define-public (register-technician (name (string-ascii 50)) (certification-level uint) (specializations (list 3 (string-ascii 30))))
    (begin
        (asserts! (and (> certification-level u0) (<= certification-level u5)) ERR_INVALID_MAINTENANCE)

        (map-set certified-technicians tx-sender {
            name: name,
            certification-level: certification-level,
            specializations: specializations,
            total-inspections: u0,
            rating: u100,
            is-active: true,
            certified-since: block-height
        })

        (print {event: "technician-registered", technician: tx-sender, level: certification-level})
        (ok true)
    )
)

;; Update maintenance status
(define-public (update-maintenance-status (maintenance-id uint) (status (string-ascii 20)))
    (let ((maintenance (unwrap! (map-get? maintenance-schedules maintenance-id) ERR_NOT_FOUND)))
        (asserts! (or
            (is-eq tx-sender (get scheduled-by maintenance))
            (is-eq (some tx-sender) (get assigned-technician maintenance))
            (is-eq tx-sender CONTRACT_OWNER)
        ) ERR_UNAUTHORIZED)

        (map-set maintenance-schedules maintenance-id
            (merge maintenance {status: status}))

        (print {event: "maintenance-status-updated", maintenance-id: maintenance-id, status: status})
        (ok true)
    )
)

;; Read-only Functions

;; Get maintenance record
(define-read-only (get-maintenance-record (ladder-id uint))
    (map-get? ladder-maintenance-records ladder-id)
)

;; Get maintenance schedule
(define-read-only (get-maintenance-schedule (maintenance-id uint))
    (map-get? maintenance-schedules maintenance-id)
)

;; Get inspection report
(define-read-only (get-inspection-report (inspection-id uint))
    (map-get? inspection-reports inspection-id)
)

;; Get technician info
(define-read-only (get-technician-info (technician principal))
    (map-get? certified-technicians technician)
)

;; Check if ladder needs maintenance
(define-read-only (needs-maintenance (ladder-id uint))
    (match (map-get? ladder-maintenance-records ladder-id)
        record (>= block-height (get next-inspection-due record))
        false
    )
)

;; Check if ladder is certified
(define-read-only (is-ladder-certified (ladder-id uint))
    (match (map-get? ladder-maintenance-records ladder-id)
        record (and
            (get is-certified record)
            (> (get certification-expires record) block-height)
        )
        false
    )
)

;; Get overdue maintenance count
(define-read-only (get-maintenance-stats)
    {
        total-maintenance-records: (var-get next-maintenance-id),
        total-inspections: (var-get next-inspection-id),
        maintenance-interval-blocks: (var-get maintenance-interval)
    }
)

;; Private Functions

;; Calculate maintenance cost based on type and priority
(define-private (calculate-maintenance-cost (maintenance-type (string-ascii 30)) (priority (string-ascii 10)))
    (let (
        (base-cost (if (is-eq maintenance-type "inspection") u50
                    (if (is-eq maintenance-type "repair") u150
                        u300))) ;; certification
        (priority-multiplier (if (is-eq priority "urgent") u200
                            (if (is-eq priority "high") u150
                                u100)))
    )
        (/ (* base-cost priority-multiplier) u100)
    )
)

;; Calculate overall maintenance score
(define-private (calculate-overall-score (safety uint) (structural uint) (wear uint))
    (/ (+ (* safety u40) (* structural u35) (* wear u25)) u100)
)
