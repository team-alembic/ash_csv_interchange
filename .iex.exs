import_if_available(MyPackage)

# Load a project-local .iex.exs if it exists (gitignored for personal tweaks).
if File.exists?(".iex.local.exs"), do: Code.require_file(".iex.local.exs")
