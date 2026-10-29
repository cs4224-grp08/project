package workload

import "slices"

var WorkloadNames = []string{"A", "B"}

type Attribute struct {
	AttributeName  string
	AttributeBytes float64
	AttributeIsKey bool
}

type Entity struct {
	EntityName        string
	EntityTables      []string
	EntityCardinality float64
	EntityAttributes  []Attribute
}

type EntityAccess struct {
	EntityName         string
	RestrictAttributes []string
	ReadAttributes     []string
	WriteAttributes    []string
	AccessedRecords    float64
}

type Transaction struct {
	TransactionName     string
	TransactionWeights  map[string]float64
	TransactionAccesses []EntityAccess
}

const (
	customerCount        = 1_000_000
	productCount         = 500_000
	orderCount           = 5_000_000
	orderItemCount       = 15_000_000
	averageItemsPerOrder = 3
	salesReportDays      = 30
	orderHistoryDays     = 365
)

var Entities = []Entity{
	{
		EntityName:        "customer",
		EntityTables:      []string{"customers"},
		EntityCardinality: customerCount,
		EntityAttributes: []Attribute{
			{AttributeName: "customer_id", AttributeBytes: 8, AttributeIsKey: true},
			{AttributeName: "merchant_id", AttributeBytes: 8, AttributeIsKey: true},
			{AttributeName: "customer_name", AttributeBytes: 15.9},
			{AttributeName: "email", AttributeBytes: 28.9},
			{AttributeName: "created_at", AttributeBytes: 8},
		},
	},
	{
		EntityName:        "product",
		EntityTables:      []string{"products", "inventory"},
		EntityCardinality: productCount,
		EntityAttributes: []Attribute{
			{AttributeName: "product_id", AttributeBytes: 8, AttributeIsKey: true},
			{AttributeName: "merchant_id", AttributeBytes: 8, AttributeIsKey: true},
			{AttributeName: "product_name", AttributeBytes: 14.8},
			{AttributeName: "category", AttributeBytes: 11},
			{AttributeName: "price", AttributeBytes: 8},
			{AttributeName: "quantity", AttributeBytes: 4},
			{AttributeName: "updated_at", AttributeBytes: 8},
		},
	},
	{
		EntityName:        "order",
		EntityTables:      []string{"orders"},
		EntityCardinality: orderCount,
		EntityAttributes: []Attribute{
			{AttributeName: "order_id", AttributeBytes: 8, AttributeIsKey: true},
			{AttributeName: "merchant_id", AttributeBytes: 8, AttributeIsKey: true},
			{AttributeName: "customer_id", AttributeBytes: 8},
			{AttributeName: "order_status", AttributeBytes: 8.7},
			{AttributeName: "total_amount", AttributeBytes: 9},
			{AttributeName: "created_at", AttributeBytes: 8},
		},
	},
	{
		EntityName:        "order_item",
		EntityTables:      []string{"order_items"},
		EntityCardinality: orderItemCount,
		EntityAttributes: []Attribute{
			{AttributeName: "order_item_id", AttributeBytes: 8, AttributeIsKey: true},
			{AttributeName: "merchant_id", AttributeBytes: 8, AttributeIsKey: true},
			{AttributeName: "order_id", AttributeBytes: 8},
			{AttributeName: "product_id", AttributeBytes: 8},
			{AttributeName: "quantity", AttributeBytes: 4},
			{AttributeName: "unit_price", AttributeBytes: 8},
		},
	},
}

var Transactions = []Transaction{
	{
		TransactionName:    "T1",
		TransactionWeights: map[string]float64{"A": 36, "B": 10},
		TransactionAccesses: []EntityAccess{
			// EXISTS never evaluates its select list
			{EntityName: "customer", AccessedRecords: 1},
			{EntityName: "product", ReadAttributes: []string{"price", "quantity"}, WriteAttributes: []string{"quantity", "updated_at"}, AccessedRecords: averageItemsPerOrder},
			{EntityName: "order", WriteAttributes: []string{"customer_id", "order_status", "total_amount", "created_at"}, AccessedRecords: 1},
			{EntityName: "order_item", WriteAttributes: []string{"order_id", "product_id", "quantity", "unit_price"}, AccessedRecords: averageItemsPerOrder},
		},
	},
	{
		TransactionName:    "T2",
		TransactionWeights: map[string]float64{"A": 20, "B": 10},
		TransactionAccesses: []EntityAccess{
			{EntityName: "product", ReadAttributes: []string{"quantity"}, WriteAttributes: []string{"quantity", "updated_at"}, AccessedRecords: 1},
		},
	},
	{
		TransactionName:    "T3",
		TransactionWeights: map[string]float64{"A": 10, "B": 5},
		TransactionAccesses: []EntityAccess{
			{EntityName: "order", RestrictAttributes: []string{"customer_id", "created_at"}, ReadAttributes: []string{"order_status", "total_amount", "created_at"}, AccessedRecords: orderCount / customerCount},
			{EntityName: "order_item", RestrictAttributes: []string{"order_id"}, ReadAttributes: []string{"product_id", "quantity", "unit_price"}, AccessedRecords: orderCount / customerCount * averageItemsPerOrder},
		},
	},
	{
		TransactionName:    "T4",
		TransactionWeights: map[string]float64{"A": 10, "B": 5},
		TransactionAccesses: []EntityAccess{
			{EntityName: "product", ReadAttributes: []string{"product_name", "category", "price", "quantity"}, AccessedRecords: 1},
		},
	},
	{
		TransactionName:    "T5",
		TransactionWeights: map[string]float64{"A": 10, "B": 10},
		TransactionAccesses: []EntityAccess{
			{EntityName: "order", WriteAttributes: []string{"order_status"}, AccessedRecords: 1},
		},
	},
	{
		TransactionName:    "T6",
		TransactionWeights: map[string]float64{"A": 5, "B": 10},
		TransactionAccesses: []EntityAccess{
			{EntityName: "order", RestrictAttributes: []string{"created_at"}, ReadAttributes: []string{"total_amount"}, AccessedRecords: orderCount * salesReportDays / orderHistoryDays},
		},
	},
	{
		TransactionName:    "T7",
		TransactionWeights: map[string]float64{"A": 5, "B": 30},
		TransactionAccesses: []EntityAccess{
			{EntityName: "product", ReadAttributes: []string{"quantity"}, WriteAttributes: []string{"quantity", "updated_at"}, AccessedRecords: 2},
		},
	},
	{
		TransactionName:    "T8",
		TransactionWeights: map[string]float64{"A": 2, "B": 10},
		TransactionAccesses: []EntityAccess{
			{EntityName: "customer", WriteAttributes: []string{"email"}, AccessedRecords: 1},
		},
	},
	{
		TransactionName:    "T9",
		TransactionWeights: map[string]float64{"A": 2, "B": 10},
		TransactionAccesses: []EntityAccess{
			{EntityName: "product", ReadAttributes: []string{"price"}, WriteAttributes: []string{"price"}, AccessedRecords: 1},
		},
	},
}

func (entity Entity) NonKeyAttributes() []Attribute {
	var nonKeyAttributes []Attribute
	for _, attribute := range entity.EntityAttributes {
		if !attribute.AttributeIsKey {
			nonKeyAttributes = append(nonKeyAttributes, attribute)
		}
	}

	return nonKeyAttributes
}

func (access EntityAccess) RestrictsAttribute(attributeName string) bool {
	return slices.Contains(access.RestrictAttributes, attributeName)
}

func (access EntityAccess) UsesAttribute(attributeName string) bool {
	return access.RestrictsAttribute(attributeName) ||
		slices.Contains(access.ReadAttributes, attributeName) ||
		slices.Contains(access.WriteAttributes, attributeName)
}
