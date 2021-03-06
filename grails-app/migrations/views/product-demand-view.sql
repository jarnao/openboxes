CREATE OR REPLACE VIEW product_demand AS
SELECT
    -- request data
    request_id,
    request_status,
    request_number,
    date_created,
    date_requested,
    date_issued,
    origin_id,
    origin_name,
    destination_id,
    destination_name,

    -- request item data
    request_item_id,
    product_id,
    product_code,
    product_name,
    quantity_requested,
    quantity_canceled,
    quantity_approved,
    quantity_modified,
    quantity_picked,
    cancel_reason_code,
    cancel_comments,
    pick_reason_code,
    request_item_status,
    reason_code_classification,

    -- pick list item data
    picklist_reason_code,

    -- reason code
	  COALESCE(cancel_reason_code, pick_reason_code, picklist_reason_code) AS reason_code,

    -- request item status
    CASE
        WHEN request_item_status = 'SUBSTITUTION'
            THEN 'ITEM_SUBSTITUTED'
        WHEN quantity_requested = quantity_canceled AND quantity_picked = 0
            THEN 'ITEM_CANCELED'
        WHEN quantity_requested = quantity_approved AND quantity_picked != quantity_approved
            THEN 'PICK_MODIFIED'
        WHEN quantity_requested != quantity_approved AND quantity_picked = quantity_approved
            THEN 'ITEM_MODIFIED'
        WHEN quantity_picked > 0 THEN 'ITEM_ISSUED'
        ELSE NULL
        END as request_item_change_status,

    -- quantity demand
    CASE
        WHEN request_item_status = 'SUBSTITUTION'
            THEN quantity_requested
        WHEN quantity_picked > quantity_requested
            THEN quantity_picked
        WHEN quantity_picked < quantity_requested AND
             reason_code_classification IN (NULL, 'INSUFFICIENT_QUANTITY_AVAILABLE')
            THEN quantity_requested
        WHEN quantity_picked < quantity_requested AND
             reason_code_classification IN ('CLINICAL_JUDGMENT')
            THEN quantity_picked
        ELSE quantity_requested
        END as quantity_demand
FROM (
         SELECT request_id,
                request_item_id,
                request_status,
                request_number,
                date_created,
                date_requested,
                date_issued,
                origin_id,
                origin_name,
                destination_id,
                destination_name,
                product_id,
                product_code,
                product_name,
                quantity_requested,
                IFNULL(quantity_canceled, 0) AS quantity_canceled,
                IFNULL(quantity_approved, 0) AS quantity_approved,
                IFNULL(quantity_modified, 0) AS quantity_modified,
                IFNULL(quantity_picked, 0)   AS quantity_picked,
                cancel_reason_code,
                cancel_comments,
                pick_reason_code,
                reason_code_classification,
                request_item_status,
                picklist_reason_code
         FROM (
                  SELECT requisition.id                      as request_id,
                         requisition_item.id                 as request_item_id,
                         requisition.status                  AS request_status,
                         requisition.request_number,
                         requisition.date_created            as date_created,
                         requisition.date_requested          AS date_requested,
                         requisition_transaction.date_issued AS date_issued,
                         origin.id                           AS origin_id,
                         origin.name                         AS origin_name,
                         destination.id                      AS destination_id,
                         destination.name                    AS destination_name,
                         child_request_item.status           as request_item_status,
                         product.id                          AS product_id,
                         product.product_code,
                         product.name                        AS product_name,
                         cancel_reason_code,
                         -- FIXME converting from boolean to string does not strike me as a good idea here
                         CASE
                             WHEN insufficient_quantity_available > 0
                                 THEN 'INSUFFICIENT_QUANTITY_AVAILABLE'
                             WHEN clinical_judgment > 0 THEN 'CLINICAL_JUDGMENT'
                             ELSE NULL
                             END                             as reason_code_classification,
                         insufficient_quantity_available,
                         clinical_judgment,
                         cancel_comments,
                         pick_reason_code,
                         quantity                            AS quantity_requested,
                         quantity_canceled,
                         quantity_approved,

                         -- quantity changed
                         (
                             SELECT SUM(quantity)
                             FROM requisition_item child
                             WHERE child.parent_requisition_item_id = requisition_item.id
                               AND requisition_item_type = 'QUANTITY_CHANGE'
                         )                                   AS quantity_modified,

                         -- quantity picked
                         picked_items.quantity_picked,

                         -- picklist item reason code
                         picked_items.picklist_reason_code as picklist_reason_code
                  FROM requisition_item
                           JOIN product ON product.id = requisition_item.product_id
                           JOIN requisition ON requisition.id = requisition_item.requisition_id
                           JOIN location destination ON destination.id = requisition.destination_id
                           JOIN location origin ON origin.id = requisition.origin_id
                           JOIN location_type on origin.location_type_id = location_type.id

                      -- Used to get issue date
                           LEFT OUTER JOIN (
                      SELECT requisition.id               as requisition_id,
                             transaction.transaction_date as date_issued
                      FROM requisition
                               JOIN shipment on shipment.requisition_id = requisition.id
                               JOIN transaction on shipment.id = transaction.outgoing_shipment_id
                  ) as requisition_transaction
                                           on requisition.id = requisition_transaction.requisition_id

                      -- Used to get quantity picked
                           LEFT OUTER JOIN (
                      SELECT ifnull(requisition_item.parent_requisition_item_id,
                                    requisition_item.id) as requisition_item_id,
                             SUM(picklist_item.quantity) as quantity_picked,
                             picklist_item.reason_code as picklist_reason_code
                      FROM picklist_item
                               join requisition_item
                                    on picklist_item.requisition_item_id = requisition_item.id
                      GROUP BY requisition_item.id, picklist_item.reason_code
                  ) as picked_items ON (picked_items.requisition_item_id = requisition_item.id)

                      -- Used to determine whether a requisition item was changed or substituted
                           LEFT OUTER JOIN (
                      SELECT requisition_item.id                            as requisition_item_id,
                             GROUP_CONCAT(distinct (child.product_id))      as products,
                             IFNULL(GROUP_CONCAT(distinct (child.requisition_item_type)),
                                    requisition_item.requisition_item_type) as status
                      FROM requisition_item
                               LEFT OUTER JOIN requisition_item child
                                               on child.parent_requisition_item_id = requisition_item.id
                      GROUP BY requisition_item.id
                  ) as child_request_item ON requisition_item.id =
                                             child_request_item.requisition_item_id

                      -- Used to classify whether a request item was changed or canceled due to reason code related to insufficient quantity available
                           LEFT OUTER JOIN (
                      select parent_item.id as requisition_item_id,
                             -- check all reason codes for insufficient quantity available
                             sum(if(parent_item.cancel_reason_code in
                                    ('STOCKOUT', 'LOW_STOCK', 'COULD_NOT_LOCATE')
                                        or parent_item.pick_reason_code in
                                           ('STOCKOUT', 'LOW_STOCK', 'COULD_NOT_LOCATE')
                                        or child_item.cancel_reason_code in
                                           ('STOCKOUT', 'LOW_STOCK', 'COULD_NOT_LOCATE')
                                        or child_item.pick_reason_code in
                                           ('STOCKOUT', 'LOW_STOCK', 'COULD_NOT_LOCATE')
                                        or parent_picklist_item.reason_code in
                                           ('STOCKOUT', 'LOW_STOCK', 'COULD_NOT_LOCATE')
                                        or child_picklist_item.reason_code in
                                           ('STOCKOUT', 'LOW_STOCK', 'COULD_NOT_LOCATE'), true,
                                    false)) as insufficient_quantity_available,
                             -- otherwise the reason code is probably related to a clinical judgment
                             sum((coalesce(parent_item.cancel_reason_code,
                                           child_item.cancel_reason_code,
                                           parent_item.pick_reason_code,
                                           child_item.pick_reason_code,
                                           parent_picklist_item.reason_code,
                                           child_picklist_item.reason_code) !=
                                  ''))      as clinical_judgment
                      from requisition_item parent_item
                               left outer join requisition_item child_item
                                               on child_item.parent_requisition_item_id = parent_item.id
                               left outer join picklist_item parent_picklist_item
                                               on parent_item.id = parent_picklist_item.requisition_item_id
                               left outer join picklist_item child_picklist_item
                                               on child_item.id = child_picklist_item.requisition_item_id
                      group by parent_item.id
                  ) as reason_codes on requisition_item.id = reason_codes.requisition_item_id

                  WHERE requisition_item.requisition_item_type = 'ORIGINAL'
                    AND location_type.location_type_code = 'DEPOT'
                    AND requisition.status = 'ISSUED'
              ) AS tmp1
     ) AS tmp2;
