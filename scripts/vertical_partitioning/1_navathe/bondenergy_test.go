package navathe

import (
	"math/rand/v2"
	"slices"
	"testing"
)

func TestBondEnergyOrderIsPermutationOfAttributes(t *testing.T) {
	for seed := range uint64(200) {
		random := rand.New(rand.NewPCG(seed, 0))
		attributeMatrix := randomSymmetricMatrix(random)

		attributeOrder := BondEnergyOrder(attributeMatrix)

		if !slices.Equal(slices.Sorted(slices.Values(attributeOrder)), schemaAttributeOrder(len(attributeMatrix))) {
			t.Fatalf("seed %d: order %v is not a permutation of %d attributes", seed, attributeOrder, len(attributeMatrix))
		}
	}
}

func TestBondEnergyOrderRegroupsWellSeparatedShuffledBlocks(t *testing.T) {
	for seed := range uint64(2000) {
		random := rand.New(rand.NewPCG(seed, 0))
		attributeBlocks := shuffledBlockLabels(random)
		attributeMatrix := newSquareMatrix(len(attributeBlocks))
		for firstAttribute := range attributeMatrix {
			for secondAttribute := range firstAttribute + 1 {
				similarity := 0.05 * random.Float64()
				if attributeBlocks[firstAttribute] == attributeBlocks[secondAttribute] {
					similarity = 0.9 + 0.1*random.Float64()
				}
				attributeMatrix[firstAttribute][secondAttribute] = similarity
				attributeMatrix[secondAttribute][firstAttribute] = similarity
			}
		}

		attributeOrder := BondEnergyOrder(attributeMatrix)

		if !blocksAreContiguous(attributeOrder, attributeBlocks) {
			t.Fatalf("seed %d: blocks %v, order %v", seed, attributeBlocks, attributeOrder)
		}
	}
}

func TestPermutedMatrixReordersRowsAndColumns(t *testing.T) {
	attributeMatrix := [][]float64{
		{1, 2, 3},
		{2, 4, 5},
		{3, 5, 6},
	}

	permutedAttributeMatrix := PermutedMatrix(attributeMatrix, []int{2, 0, 1})

	wantMatrix := [][]float64{
		{6, 3, 5},
		{3, 1, 2},
		{5, 2, 4},
	}
	if !slices.EqualFunc(permutedAttributeMatrix, wantMatrix, slices.Equal) {
		t.Errorf("permuted matrix %v, want %v", permutedAttributeMatrix, wantMatrix)
	}
}

func randomSymmetricMatrix(random *rand.Rand) [][]float64 {
	attributeMatrix := newSquareMatrix(2 + random.IntN(6))
	for firstAttribute := range attributeMatrix {
		for secondAttribute := range firstAttribute + 1 {
			value := random.Float64()
			attributeMatrix[firstAttribute][secondAttribute] = value
			attributeMatrix[secondAttribute][firstAttribute] = value
		}
	}

	return attributeMatrix
}

func shuffledBlockLabels(random *rand.Rand) []int {
	attributeBlocks := make([]int, 3+random.IntN(6))
	blockCount := 2 + random.IntN(2)
	for attribute := range attributeBlocks {
		attributeBlocks[attribute] = attribute % blockCount
	}
	random.Shuffle(len(attributeBlocks), func(first, second int) {
		attributeBlocks[first], attributeBlocks[second] = attributeBlocks[second], attributeBlocks[first]
	})

	return attributeBlocks
}

func blocksAreContiguous(attributeOrder, attributeBlocks []int) bool {
	seenBlocks := map[int]bool{}
	for position, attribute := range attributeOrder {
		block := attributeBlocks[attribute]
		if position > 0 && block != attributeBlocks[attributeOrder[position-1]] && seenBlocks[block] {
			return false
		}
		seenBlocks[block] = true
	}

	return true
}

func schemaAttributeOrder(attributeCount int) []int {
	attributeOrder := make([]int, attributeCount)
	for attribute := range attributeOrder {
		attributeOrder[attribute] = attribute
	}

	return attributeOrder
}
