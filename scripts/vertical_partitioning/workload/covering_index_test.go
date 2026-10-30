package workload_test

import (
	"slices"
	"testing"

	navathe "github.com/cs4224-grp08/project/scripts/vertical_partitioning/1_navathe"
	hillclimb "github.com/cs4224-grp08/project/scripts/vertical_partitioning/2_hillclimb"
	autopart "github.com/cs4224-grp08/project/scripts/vertical_partitioning/3_autopart"
	"github.com/cs4224-grp08/project/scripts/vertical_partitioning/workload"
)

const cacheLineBytes = 64

var autopartParameters = autopart.PartitioningParameters{ScanScalingFactor: 1, FragmentJoinCost: 18.76, MinimumQueryExtent: 1}

type algorithmFragments func(entity workload.Entity, workloadName string) [][]int

var algorithms = map[string]algorithmFragments{
	"Navathe": func(entity workload.Entity, workloadName string) [][]int {
		attributeUsages := navathe.AttributeUsages(entity, entity.NonKeyAttributes(), workloadName)

		return navathe.Fragments(attributeUsages, entity.NonKeyAttributeBytes(), navathe.PartitioningOptions{})
	},
	"HillClimb": func(entity workload.Entity, workloadName string) [][]int {
		queryAccesses := hillclimb.QueryAccesses(entity, entity.NonKeyAttributes(), workloadName)

		return hillclimb.HillClimb(queryAccesses, entity.NonKeyAttributeBytes(), cacheLineBytes)
	},
	"AutoPart": func(entity workload.Entity, workloadName string) [][]int {
		queryAccessSets := autopart.QueryAccessSets(entity, entity.NonKeyAttributes(), workloadName)

		return autopart.Partitioning(queryAccessSets, entity.NonKeyAttributeBytes(), autopartParameters)
	},
}

func fragmentCounts(workloadName string) map[string]map[string]int {
	fragmentCounts := map[string]map[string]int{}
	for algorithmName, fragments := range algorithms {
		fragmentCounts[algorithmName] = map[string]int{}
		for _, entityName := range []string{"customer", "order"} {
			fragmentCounts[algorithmName][entityName] = len(fragments(workload.EntityNamed(entityName), workloadName))
		}
	}

	return fragmentCounts
}

func TestCoveringIndexRemovesOrdersSplitsButKeepsCustomersSplit(t *testing.T) {
	originalTransactions := slices.Clone(workload.Transactions)
	t.Cleanup(func() { workload.Transactions = originalTransactions })

	// customer, order: fragment counts with T6 scanning orders (expt_a204), then answered by the index (expt_a205)
	wantScanCounts := map[string]map[string]int{
		"Navathe":   {"customer": 1, "order": 2},
		"HillClimb": {"customer": 1, "order": 2},
		"AutoPart":  {"customer": 2, "order": 1},
	}
	wantCoveringIndexCounts := map[string]map[string]int{
		"Navathe":   {"customer": 1, "order": 1},
		"HillClimb": {"customer": 1, "order": 1},
		"AutoPart":  {"customer": 2, "order": 1},
	}

	for _, workloadName := range workload.WorkloadNames {
		workload.Transactions = slices.Clone(originalTransactions)
		if gotCounts := fragmentCounts(workloadName); !mapsEqual(gotCounts, wantScanCounts) {
			t.Errorf("workload %s, T6 scans orders: fragments %v, want %v", workloadName, gotCounts, wantScanCounts)
		}

		workload.UseCoveringIndexForGlobalSales()
		if gotCounts := fragmentCounts(workloadName); !mapsEqual(gotCounts, wantCoveringIndexCounts) {
			t.Errorf("workload %s, covering index: fragments %v, want %v", workloadName, gotCounts, wantCoveringIndexCounts)
		}
	}
}

func mapsEqual(gotCounts, wantCounts map[string]map[string]int) bool {
	for algorithmName, wantEntityCounts := range wantCounts {
		for entityName, wantCount := range wantEntityCounts {
			if gotCounts[algorithmName][entityName] != wantCount {
				return false
			}
		}
	}

	return true
}
