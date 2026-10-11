ifndef MK_LOCAL_TEST_INCLUDED
MK_LOCAL_TEST_INCLUDED := 1

.PHONY: test
test: ## Test the inline scripts of the reusable workflows (stub gh, no token)
	@"$(REPO_ROOT)/scripts/test-simple-tag-and-release.sh"
	@"$(REPO_ROOT)/scripts/test-pre-commit-warmup.sh"

endif # MK_LOCAL_TEST_INCLUDED
