package hillclimb

import (
	"math"
	"math/rand/v2"
	"slices"
	"testing"
)

const (
	priorityAttribute = iota
	locationAttribute
	usageAttribute
)

var figureFiveQueryAccesses = []QueryAccess{{QueryName: "q", QueryFrequency: 1, QueryAccessRates: []float64{1, 0.125, 0.125}}}

var figureFiveAttributeBytes = []float64{4, 4, 4}

const figureFiveCacheLineBytes = 32

func TestGroupCostsMatchTable2(t *testing.T) {
	testCases := []struct {
		group    []int
		wantCost float64
	}{
		{[]int{priorityAttribute}, 0.125},
		{[]int{locationAttribute}, 0.125},
		{[]int{usageAttribute}, 0.125},
		{[]int{priorityAttribute, locationAttribute}, 0.25},
		{[]int{priorityAttribute, usageAttribute}, 0.25},
		{[]int{locationAttribute, usageAttribute}, 0.125},
		{[]int{priorityAttribute, locationAttribute, usageAttribute}, 0.375},
	}

	for _, testCase := range testCases {
		if gotCost := GroupCost(figureFiveQueryAccesses, figureFiveAttributeBytes, testCase.group, figureFiveCacheLineBytes); math.Abs(gotCost-testCase.wantCost) > 1e-12 {
			t.Errorf("group %v: cost %g, want %g", testCase.group, gotCost, testCase.wantCost)
		}
	}
}

func TestHillClimbMatchesWorkedExample(t *testing.T) {
	gotPartition := sortedPartition(HillClimb(figureFiveQueryAccesses, figureFiveAttributeBytes, figureFiveCacheLineBytes))

	if wantPartition := [][]int{{priorityAttribute}, {locationAttribute, usageAttribute}}; !slices.EqualFunc(gotPartition, wantPartition, slices.Equal) {
		t.Errorf("partition %v, want %v", gotPartition, wantPartition)
	}
}

func TestHillClimbMergesGroupsWhenCostIsUnchanged(t *testing.T) {
	queryAccesses := []QueryAccess{{QueryFrequency: 1, QueryAccessRates: []float64{1e-6, 0}}}

	if gotPartition := HillClimb(queryAccesses, []float64{8, 8}, 64); len(gotPartition) != 1 {
		t.Errorf("partition %v, want one group", gotPartition)
	}
}

func TestEveryPartitionCountsBellNumbers(t *testing.T) {
	for attributeCount, bellNumber := range []int{1, 1, 2, 5, 15, 52, 203} {
		if gotCount := len(everyPartition(attributeCount)); gotCount != bellNumber {
			t.Errorf("%d attributes: %d partitions, want %d", attributeCount, gotCount, bellNumber)
		}
	}
}

func TestHillClimbNeverCostsMoreThanStartingPartition(t *testing.T) {
	for seed := range uint64(500) {
		random := rand.New(rand.NewPCG(seed, 0))
		queryAccesses, attributeBytes := randomQueryAccesses(random)
		singletonPartition := make([][]int, len(attributeBytes))
		for attribute := range singletonPartition {
			singletonPartition[attribute] = []int{attribute}
		}

		hillClimbCost := PartitionCost(queryAccesses, attributeBytes, HillClimb(queryAccesses, attributeBytes, 64), 64)
		naiveCost := PartitionCost(queryAccesses, attributeBytes, Naive(queryAccesses, attributeBytes, 64), 64)
		singletonCost := PartitionCost(queryAccesses, attributeBytes, singletonPartition, 64)

		if hillClimbCost > singletonCost+1e-12 || naiveCost > hillClimbCost+1e-12 {
			t.Fatalf("seed %d: naive %g, hill climb %g, singletons %g", seed, naiveCost, hillClimbCost, singletonCost)
		}
	}
}

func randomQueryAccesses(random *rand.Rand) ([]QueryAccess, []float64) {
	attributeBytes := make([]float64, 2+random.IntN(5))
	for attribute := range attributeBytes {
		attributeBytes[attribute] = 1 + 30*random.Float64()
	}

	queryAccesses := make([]QueryAccess, 1+random.IntN(6))
	for queryIndex := range queryAccesses {
		queryAccessRates := make([]float64, len(attributeBytes))
		for attribute := range queryAccessRates {
			queryAccessRates[attribute] = []float64{0, random.Float64(), 1}[random.IntN(3)]
		}
		queryAccesses[queryIndex] = QueryAccess{QueryFrequency: 1 + 10*random.Float64(), QueryAccessRates: queryAccessRates}
	}

	return queryAccesses, attributeBytes
}

func sortedPartition(partition [][]int) [][]int {
	sorted := make([][]int, len(partition))
	for groupIndex, group := range partition {
		sorted[groupIndex] = slices.Sorted(slices.Values(group))
	}
	slices.SortFunc(sorted, slices.Compare)

	return sorted
}
