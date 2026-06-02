# Mirrors ash-project/ash house style (with `strict: true` for CI). Quokka
# reads this file and rewrites based on the enabled checks, so turning a check
# on here also drives auto-formatting.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "src/", "test/", "config/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      # Uncomment to enable Ash-aware Credo checks (requires :ash_credo dep).
      # plugins: [{AshCredo, []}],
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: [
        # Consistency
        {Credo.Check.Consistency.ExceptionNames, []},
        {Credo.Check.Consistency.LineEndings, []},
        {Credo.Check.Consistency.ParameterPatternMatching, []},
        {Credo.Check.Consistency.SpaceAroundOperators, false},
        {Credo.Check.Consistency.SpaceInParentheses, []},
        {Credo.Check.Consistency.TabsOrSpaces, []},

        # Design — AliasUsage nags on every bare module reference; off by convention.
        {Credo.Check.Design.AliasUsage, false},
        {Credo.Check.Design.TagTODO, false},
        {Credo.Check.Design.TagFIXME, []},

        # Readability
        {Credo.Check.Readability.AliasOrder, []},
        {Credo.Check.Readability.FunctionNames, []},
        {Credo.Check.Readability.LargeNumbers, []},
        {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},
        {Credo.Check.Readability.ModuleAttributeNames, []},
        {Credo.Check.Readability.ModuleDoc, []},
        {Credo.Check.Readability.ModuleNames, []},
        {Credo.Check.Readability.ParenthesesInCondition, false},
        {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
        {Credo.Check.Readability.PredicateFunctionNames, false},
        {Credo.Check.Readability.PreferImplicitTry, []},
        {Credo.Check.Readability.RedundantBlankLines, []},
        {Credo.Check.Readability.Semicolons, []},
        {Credo.Check.Readability.SpaceAfterCommas, []},
        {Credo.Check.Readability.StringSigils, []},
        {Credo.Check.Readability.TrailingBlankLine, []},
        {Credo.Check.Readability.TrailingWhiteSpace, []},
        {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
        {Credo.Check.Readability.VariableNames, []},

        # Refactor
        {Credo.Check.Refactor.CondStatements, []},
        {Credo.Check.Refactor.CyclomaticComplexity, false},
        {Credo.Check.Refactor.FunctionArity, false},
        {Credo.Check.Refactor.LongQuoteBlocks, false},
        {Credo.Check.Refactor.MapInto, false},
        {Credo.Check.Refactor.MatchInCondition, false},
        {Credo.Check.Refactor.NegatedConditionsInUnless, []},
        {Credo.Check.Refactor.NegatedConditionsWithElse, []},
        {Credo.Check.Refactor.Nesting, [max_nesting: 10]},
        {Credo.Check.Refactor.UnlessWithElse, []},
        {Credo.Check.Refactor.WithClauses, []},

        # Warning
        {Credo.Check.Warning.BoolOperationOnSameValues, []},
        {Credo.Check.Warning.ExpensiveEmptyEnumCheck, [files: %{excluded: ["test/**/*_test.exs"]}]},
        {Credo.Check.Warning.IExPry, []},
        {Credo.Check.Warning.IoInspect, []},
        {Credo.Check.Warning.LazyLogging, false},
        {Credo.Check.Warning.MixEnv, false},
        {Credo.Check.Warning.OperationOnSameValues, []},
        {Credo.Check.Warning.OperationWithConstantResult, []},
        {Credo.Check.Warning.RaiseInsideRescue, []},
        {Credo.Check.Warning.StructFieldAmount, false},
        {Credo.Check.Warning.UnusedEnumOperation, []},
        {Credo.Check.Warning.UnusedFileOperation, []},
        {Credo.Check.Warning.UnusedKeywordOperation, []},
        {Credo.Check.Warning.UnusedListOperation, []},
        {Credo.Check.Warning.UnusedPathOperation, []},
        {Credo.Check.Warning.UnusedRegexOperation, []},
        {Credo.Check.Warning.UnusedStringOperation, []},
        {Credo.Check.Warning.UnusedTupleOperation, []},
        {Credo.Check.Warning.UnsafeExec, []},

        # Opt-in / controversial — off by ash-project convention
        {Credo.Check.Readability.StrictModuleLayout, false},
        {Credo.Check.Readability.Specs, false},
        {Credo.Check.Readability.SinglePipe, false},
        {Credo.Check.Readability.MultiAlias, false},
        {Credo.Check.Readability.AliasAs, false},
        {Credo.Check.Readability.WithCustomTaggedTuple, false},
        {Credo.Check.Consistency.MultiAliasImportRequireUse, false},
        {Credo.Check.Consistency.UnusedVariableNames, false},
        {Credo.Check.Design.DuplicatedCode, false},
        {Credo.Check.Refactor.ABCSize, false},
        {Credo.Check.Refactor.Apply, false},
        {Credo.Check.Refactor.AppendSingleItem, false},
        {Credo.Check.Refactor.DoubleBooleanNegation, false},
        {Credo.Check.Refactor.ModuleDependencies, false},
        {Credo.Check.Refactor.NegatedIsNil, false},
        {Credo.Check.Refactor.PipeChainStart, false},
        {Credo.Check.Refactor.VariableRebinding, false},
        {Credo.Check.Warning.LeakyEnvironment, false},
        {Credo.Check.Warning.MapGetUnsafePass, false},
        {Credo.Check.Warning.UnsafeToAtom, false}

        # --- AshCredo opt-in checks (uncomment when :ash_credo is enabled) ---
        #
        # MissingChangeWrapper and MissingMacroDirective are on by default
        # when the plugin is loaded; the rest are opt-in. Full catalogue:
        # https://hexdocs.pm/ash_credo/readme.html#checks
        #
        # {AshCredo.Check.Warning.AuthorizeFalse, []},
        # {AshCredo.Check.Warning.AuthorizerWithoutPolicies, []},
        # {AshCredo.Check.Warning.MissingDomain, []},
        # {AshCredo.Check.Warning.MissingPrimaryKey, []},
        # {AshCredo.Check.Warning.NoActions, []},
        # {AshCredo.Check.Warning.OverlyPermissivePolicy, []},
        # {AshCredo.Check.Warning.PinnedTimeInExpression, []},
        # {AshCredo.Check.Warning.SensitiveAttributeExposed, []},
        # {AshCredo.Check.Warning.SensitiveFieldInAccept, []},
        # {AshCredo.Check.Warning.UnknownAction, []},
        # {AshCredo.Check.Warning.WildcardAcceptOnAction, []},
        # {AshCredo.Check.Refactor.DirectiveInFunctionBody, []},
        # {AshCredo.Check.Refactor.LargeResource, []},
        # {AshCredo.Check.Refactor.UseCodeInterface, []},
        # {AshCredo.Check.Design.MissingCodeInterface, []},
        # {AshCredo.Check.Design.MissingIdentity, []},
        # {AshCredo.Check.Design.MissingPrimaryAction, []},
        # {AshCredo.Check.Design.MissingTimestamps, []},
        # {AshCredo.Check.Readability.ActionMissingDescription, []},
        # {AshCredo.Check.Readability.BelongsToMissingAllowNil, []}
      ]
    }
  ]
}
