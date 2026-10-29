package navathe

import (
	"slices"
	"testing"
)

var tableOneAttributeUsages = []AttributeUsage{
	{TransactionName: "T1", TransactionType: RetrievalTransaction, TransactionAccesses: 25, TransactionAttributes: []int{0, 4, 6}},
	{TransactionName: "T2", TransactionType: RetrievalTransaction, TransactionAccesses: 50, TransactionAttributes: []int{1, 2, 7, 8}},
	{TransactionName: "T3", TransactionType: RetrievalTransaction, TransactionAccesses: 25, TransactionAttributes: []int{3, 5, 9}},
	{TransactionName: "T4", TransactionType: RetrievalTransaction, TransactionAccesses: 35, TransactionAttributes: []int{1, 6, 7}},
	{TransactionName: "T5", TransactionType: UpdateTransaction, TransactionAccesses: 25, TransactionAttributes: []int{0, 1, 2, 4, 6, 7, 8}},
	{TransactionName: "T6", TransactionType: UpdateTransaction, TransactionAccesses: 25, TransactionAttributes: []int{0, 4}},
	{TransactionName: "T7", TransactionType: UpdateTransaction, TransactionAccesses: 25, TransactionAttributes: []int{2, 8}},
	{TransactionName: "T8", TransactionType: UpdateTransaction, TransactionAccesses: 15, TransactionAttributes: []int{2, 3, 5, 8, 9}},
}

var tableOneAttributeBytes = []float64{10, 8, 4, 6, 15, 14, 3, 5, 9, 12}

func TestAffinityMatrixMatchesFigure3a(t *testing.T) {
	wantAffinityMatrix := [][]float64{
		{75, 25, 25, 0, 75, 0, 50, 25, 25, 0},
		{25, 110, 75, 0, 25, 0, 60, 110, 75, 0},
		{25, 75, 115, 15, 25, 15, 25, 75, 115, 15},
		{0, 0, 15, 40, 0, 40, 0, 0, 15, 40},
		{75, 25, 25, 0, 75, 0, 50, 25, 25, 0},
		{0, 0, 15, 40, 0, 40, 0, 0, 15, 40},
		{50, 60, 25, 0, 50, 0, 85, 60, 25, 0},
		{25, 110, 75, 0, 25, 0, 60, 110, 75, 0},
		{25, 75, 115, 15, 25, 15, 25, 75, 115, 15},
		{0, 0, 15, 40, 0, 40, 0, 0, 15, 40},
	}

	gotAffinityMatrix := AffinityMatrix(tableOneAttributeUsages, len(tableOneAttributeBytes))

	if !slices.EqualFunc(gotAffinityMatrix, wantAffinityMatrix, slices.Equal) {
		t.Errorf("affinity matrix %v, want %v", gotAffinityMatrix, wantAffinityMatrix)
	}
}

func TestNonOverlappingFragmentsMatchFigure9a(t *testing.T) {
	gotFragments := sortedFragments(Fragments(tableOneAttributeUsages, tableOneAttributeBytes, PartitioningOptions{}))

	wantFragments := [][]int{{0, 4, 6}, {1, 2, 7, 8}, {3, 5, 9}}
	if !slices.EqualFunc(gotFragments, wantFragments, slices.Equal) {
		t.Errorf("fragments %v, want %v", gotFragments, wantFragments)
	}
}

func TestFragmentsCoverEveryAttribute(t *testing.T) {
	for _, options := range everyPartitioningOption() {
		var coveredAttributes []int
		for _, fragment := range Fragments(tableOneAttributeUsages, tableOneAttributeBytes, options) {
			coveredAttributes = append(coveredAttributes, fragment...)
		}

		slices.Sort(coveredAttributes)
		if gotAttributes := slices.Compact(coveredAttributes); !slices.Equal(gotAttributes, []int{0, 1, 2, 3, 4, 5, 6, 7, 8, 9}) {
			t.Errorf("options %+v: fragments cover %v", options, gotAttributes)
		}
	}
}

func TestNonOverlappingFragmentsAreDisjoint(t *testing.T) {
	for _, options := range everyPartitioningOption() {
		if options.WithOverlap {
			continue
		}

		var fragmentAttributes []int
		for _, fragment := range Fragments(tableOneAttributeUsages, tableOneAttributeBytes, options) {
			fragmentAttributes = append(fragmentAttributes, fragment...)
		}

		if len(fragmentAttributes) != len(tableOneAttributeBytes) {
			t.Errorf("options %+v: %d attributes across fragments, want %d", options, len(fragmentAttributes), len(tableOneAttributeBytes))
		}
	}
}

func TestUpdatesOfSharedAttributesAccessBothFragments(t *testing.T) {
	upperFragment, lowerFragment := []int{0, 1}, []int{1, 2}
	retrievalUsage := AttributeUsage{TransactionType: RetrievalTransaction, TransactionAccesses: 1, TransactionAttributes: []int{1}}
	updateUsage := AttributeUsage{TransactionType: UpdateTransaction, TransactionAccesses: 1, TransactionAttributes: []int{1}}

	retrievalMatchesUpper, retrievalMatchesLower := matchedFragments(retrievalUsage, upperFragment, lowerFragment)
	updateMatchesUpper, updateMatchesLower := matchedFragments(updateUsage, upperFragment, lowerFragment)

	if !retrievalMatchesUpper || !retrievalMatchesLower {
		t.Errorf("retrieval of a shared attribute matches (%t, %t), want (true, true)", retrievalMatchesUpper, retrievalMatchesLower)
	}
	if updateMatchesUpper || updateMatchesLower {
		t.Errorf("update of a shared attribute matches (%t, %t), want (false, false)", updateMatchesUpper, updateMatchesLower)
	}
}

func everyPartitioningOption() []PartitioningOptions {
	var everyOption []PartitioningOptions
	for _, withOverlap := range []bool{false, true} {
		for _, withShift := range []bool{false, true} {
			for _, withCluster := range []bool{false, true} {
				for _, withCostFactors := range []bool{false, true} {
					everyOption = append(everyOption, PartitioningOptions{
						WithOverlap:     withOverlap,
						WithShift:       withShift,
						WithCluster:     withCluster,
						WithCostFactors: withCostFactors,
						CostFactors:     CostFactors{IrrelevantByteCost: 1, FragmentAccessCost: 1000, ReplicatedByteCost: 100},
					})
				}
			}
		}
	}

	return everyOption
}

func sortedFragments(fragments [][]int) [][]int {
	sorted := make([][]int, len(fragments))
	for fragmentIndex, fragment := range fragments {
		sorted[fragmentIndex] = slices.Sorted(slices.Values(fragment))
	}
	slices.SortFunc(sorted, slices.Compare)

	return sorted
}
