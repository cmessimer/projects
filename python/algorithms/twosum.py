from typing import List

class Solution:
    def twoSum(self, nums: List[int], target: int) -> List[int]:
        num_to_index = {}

        for i, num in enumerate(nums):
            complement = target - num
            if complement in num_to_index:
                return [num_to_index[complement], i]
            num_to_index[num] = i

        return []

#TEST CASES
def test_twoSum():
    solution = Solution()

    # Test case 1
    nums = [2, 7, 11, 15]
    target = 9
    expected_output = [0, 1]
    assert solution.twoSum(nums, target) == expected_output

    # Test case 2
    nums = [3, 2, 4]
    target = 6
    expected_output = [1, 2]
    assert solution.twoSum(nums, target) == expected_output

    # Test case 3
    nums = [3, 3]
    target = 6
    expected_output = [0, 1]
    assert solution.twoSum(nums, target) == expected_output

    print("All test cases pass")

# Run the test function
test_twoSum()

