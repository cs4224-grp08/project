// McCormick, Schweitzer and White, "Problem Decomposition and Data Reorganization by a Clustering Technique" (Operations Research 1972)

package navathe

import (
	"math"
	"slices"
)

func BondEnergyOrder(attributeMatrix [][]float64) []int {
	attributeOrder := make([]int, 0, len(attributeMatrix))
	for newAttribute := range len(attributeMatrix) {
		if len(attributeOrder) < 2 {
			attributeOrder = append(attributeOrder, newAttribute)
			continue
		}

		bestGap, bestBondEnergy := 0, math.Inf(-1)
		for gap := 0; gap <= len(attributeOrder); gap++ {
			leftPosition, rightPosition := gap-1, gap
			gapBondEnergy := positionBond(attributeMatrix, attributeOrder, leftPosition, newAttribute) +
				positionBond(attributeMatrix, attributeOrder, rightPosition, newAttribute) -
				2*adjacentBond(attributeMatrix, attributeOrder, leftPosition)
			if gapBondEnergy > bestBondEnergy {
				bestGap, bestBondEnergy = gap, gapBondEnergy
			}
		}

		attributeOrder = slices.Insert(attributeOrder, bestGap, newAttribute)
	}

	return attributeOrder
}

func positionBond(attributeMatrix [][]float64, attributeOrder []int, position, newAttribute int) float64 {
	if position < 0 || position >= len(attributeOrder) {
		return 0
	}

	return attributeBond(attributeMatrix, attributeOrder[position], newAttribute)
}

func adjacentBond(attributeMatrix [][]float64, attributeOrder []int, position int) float64 {
	if position < 0 || position+1 >= len(attributeOrder) {
		return 0
	}

	return attributeBond(attributeMatrix, attributeOrder[position], attributeOrder[position+1])
}

func attributeBond(attributeMatrix [][]float64, firstAttribute, secondAttribute int) float64 {
	var bond float64
	for row := range attributeMatrix {
		bond += attributeMatrix[row][firstAttribute] * attributeMatrix[row][secondAttribute]
	}

	return bond
}

func PermutedMatrix(attributeMatrix [][]float64, attributeOrder []int) [][]float64 {
	permutedAttributeMatrix := newSquareMatrix(len(attributeOrder))
	for rowPosition, rowAttribute := range attributeOrder {
		for columnPosition, columnAttribute := range attributeOrder {
			permutedAttributeMatrix[rowPosition][columnPosition] = attributeMatrix[rowAttribute][columnAttribute]
		}
	}

	return permutedAttributeMatrix
}

func newSquareMatrix(size int) [][]float64 {
	matrix := make([][]float64, size)
	for row := range matrix {
		matrix[row] = make([]float64, size)
	}

	return matrix
}
