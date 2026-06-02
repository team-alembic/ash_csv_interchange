[
  plugins: [DoctestFormatter, Quokka],
  inputs: ["{mix,.formatter,.credo,.check,.doctor}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  quokka: [
    # Quokka reads .credo.exs and rewrites based on those rules.
    # Exclude a few rewrites that tend to be noisy in a library context.
    exclude: [:line_length]
  ]
]
