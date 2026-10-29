package autopart

import (
	"math/rand/v2"
	"slices"
	"testing"
)

const (
	typeAttribute = iota
	errAttribute
	raAttribute
	decAttribute
	cxAttribute
	cyAttribute
	magAttribute
)

var figureOneQueryAccessSets = []QueryAccessSet{
	{QueryName: "Q1", QueryFrequency: 1, QueryAttributes: []int{typeAttribute, errAttribute}},
	{QueryName: "Q2", QueryFrequency: 1, QueryAttributes: []int{typeAttribute, raAttribute, decAttribute, magAttribute}},
	{QueryName: "Q3", QueryFrequency: 1, QueryAttributes: []int{typeAttribute, cxAttribute, cyAttribute, magAttribute}},
}

var galaxyQueryAccessSets = []QueryAccessSet{
	{QueryName: "Q2", QueryFrequency: 1, QueryAttributes: []int{raAttribute, decAttribute, magAttribute}},
	{QueryName: "Q3", QueryFrequency: 1, QueryAttributes: []int{cxAttribute, cyAttribute, magAttribute}},
}

func TestAtomicFragmentsMatchFigure1(t *testing.T) {
	gotFragments := sortedFragments(AtomicFragments(figureOneQueryAccessSets, 7))

	wantFragments := [][]int{{typeAttribute}, {errAttribute}, {raAttribute, decAttribute}, {cxAttribute, cyAttribute}, {magAttribute}}
	if !slices.EqualFunc(gotFragments, sortedFragments(wantFragments), slices.Equal) {
		t.Errorf("atomic fragments %v, want %v", gotFragments, wantFragments)
	}
}

func TestReplicationReproducesFigure1d(t *testing.T) {
	attributeBytes := []float64{0, 0, 8, 8, 8, 8, 8}
	partitioningParameters := PartitioningParameters{ScanScalingFactor: 1, FragmentJoinCost: 3, ReplicationBudget: 1, MinimumQueryExtent: 1}

	gotFragments := sortedFragments(nonEmpty(Partitioning(galaxyQueryAccessSets, attributeBytes, partitioningParameters), galaxyQueryAccessSets))

	wantFragments := sortedFragments([][]int{{raAttribute, decAttribute, magAttribute}, {cxAttribute, cyAttribute, magAttribute}})
	if !slices.EqualFunc(gotFragments, wantFragments, slices.Equal) {
		t.Errorf("fragments %v, want %v", gotFragments, wantFragments)
	}
}

func TestFreeJoinsKeepAtomicFragments(t *testing.T) {
	for seed := range uint64(200) {
		random := rand.New(rand.NewPCG(seed, 0))
		queryAccessSets, attributeBytes := randomQueryAccessSets(random)
		partitioningParameters := PartitioningParameters{ScanScalingFactor: 1, FragmentJoinCost: 0, ReplicationBudget: 0, MinimumQueryExtent: 1}

		gotFragments := sortedFragments(Partitioning(queryAccessSets, attributeBytes, partitioningParameters))

		if wantFragments := sortedFragments(AtomicFragments(queryAccessSets, len(attributeBytes))); !slices.EqualFunc(gotFragments, wantFragments, slices.Equal) {
			t.Fatalf("seed %d: fragments %v, want atomic fragments %v", seed, gotFragments, wantFragments)
		}
	}
}

func TestExpensiveJoinsMergeEveryUsedAttribute(t *testing.T) {
	partitioningParameters := PartitioningParameters{ScanScalingFactor: 1, FragmentJoinCost: 1000, ReplicationBudget: 0, MinimumQueryExtent: 1}

	gotFragments := Partitioning(figureOneQueryAccessSets, []float64{8, 8, 8, 8, 8, 8, 8}, partitioningParameters)

	if len(gotFragments) != 1 || len(gotFragments[0]) != 7 {
		t.Errorf("fragments %v, want one fragment of all 7 attributes", gotFragments)
	}
}

func TestWithoutReplicationBudgetFragmentsAreDisjoint(t *testing.T) {
	for seed := range uint64(200) {
		random := rand.New(rand.NewPCG(seed, 0))
		queryAccessSets, attributeBytes := randomQueryAccessSets(random)
		partitioningParameters := PartitioningParameters{ScanScalingFactor: 1, FragmentJoinCost: 4 * random.Float64(), ReplicationBudget: 0, MinimumQueryExtent: 1}

		fragments := Partitioning(queryAccessSets, attributeBytes, partitioningParameters)

		var storedAttributes []int
		for _, fragment := range fragments {
			storedAttributes = append(storedAttributes, fragment...)
		}
		slices.Sort(storedAttributes)
		if !slices.Equal(storedAttributes, schemaAttributeOrder(len(attributeBytes))) {
			t.Fatalf("seed %d: fragments %v store attributes %v", seed, fragments, storedAttributes)
		}
	}
}

func TestAddFragmentReplacesItsSubsets(t *testing.T) {
	gotSchema := addFragment([][]int{{0}, {1, 2}, {3}}, []int{0, 1, 2})

	if wantSchema := [][]int{{3}, {0, 1, 2}}; !slices.EqualFunc(gotSchema, wantSchema, slices.Equal) {
		t.Errorf("schema %v, want %v", gotSchema, wantSchema)
	}
}

func randomQueryAccessSets(random *rand.Rand) ([]QueryAccessSet, []float64) {
	attributeBytes := make([]float64, 2+random.IntN(6))
	for attribute := range attributeBytes {
		attributeBytes[attribute] = 1 + 30*random.Float64()
	}

	queryAccessSets := make([]QueryAccessSet, 1+random.IntN(6))
	for queryIndex := range queryAccessSets {
		var queryAttributes []int
		for attribute := range attributeBytes {
			if random.IntN(2) == 0 {
				queryAttributes = append(queryAttributes, attribute)
			}
		}
		if len(queryAttributes) == 0 {
			queryAttributes = []int{random.IntN(len(attributeBytes))}
		}
		queryAccessSets[queryIndex] = QueryAccessSet{QueryFrequency: 1 + 10*random.Float64(), QueryAttributes: queryAttributes}
	}

	return queryAccessSets, attributeBytes
}

func nonEmpty(fragments [][]int, queryAccessSets []QueryAccessSet) [][]int {
	var usedFragments [][]int
	for _, fragment := range fragments {
		for _, queryAccessSet := range queryAccessSets {
			if len(intersection(fragment, queryAccessSet.QueryAttributes)) > 0 {
				usedFragments = append(usedFragments, fragment)
				break
			}
		}
	}

	return usedFragments
}

func sortedFragments(fragments [][]int) [][]int {
	sorted := make([][]int, len(fragments))
	for fragmentIndex, fragment := range fragments {
		sorted[fragmentIndex] = slices.Sorted(slices.Values(fragment))
	}
	slices.SortFunc(sorted, slices.Compare)

	return sorted
}

func schemaAttributeOrder(attributeCount int) []int {
	attributeOrder := make([]int, attributeCount)
	for attribute := range attributeOrder {
		attributeOrder[attribute] = attribute
	}

	return attributeOrder
}
