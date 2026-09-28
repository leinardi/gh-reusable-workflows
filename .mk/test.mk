ifndef MK_LOCAL_TEST_INCLUDED
MK_LOCAL_TEST_INCLUDED := 1

.PHONY: test
test: ## Test the inline scripts of the reusable release workflow
	@"$(REPO_ROOT)/scripts/test-simple-tag-and-release.sh"

endif # MK_LOCAL_TEST_INCLUDED
