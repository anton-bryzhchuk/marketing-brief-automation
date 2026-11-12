# Live Anthropic test results

The live test has not been run. The local project had no Anthropic API key configured when this report was prepared. The Docker Compose acceptance suite was run with the bundled mock.

## Run the live test

1. Add your key as `ANTHROPIC_API_KEY` in the project's ignored `.env` file. Set `MOCK_LLM=false` in that file. Set `CLAUDE_MODEL=claude-sonnet-5-5` to use Anthropic's documented replacement for the project's Sonnet 4.5 default.
2. Apply the environment changes and run both requests.

   ```sh
   cd ~/marketing-brief-automation
   docker compose up -d --wait --force-recreate n8n
   ./scripts/test.sh live
   ```

3. Review the updated report in this file. It records the configured model, HTTP and workflow statuses, validation checks, and webhook duration for English and German. Set `MOCK_LLM=true` in `.env` and run `docker compose up -d --wait --force-recreate n8n` to restore the mock.

See [Anthropic's model deprecation schedule](https://platform.claude.com/docs/en/about-claude/model-deprecations) for supported model IDs.
