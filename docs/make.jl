using Documenter
using NGCSimLib

DocMeta.setdocmeta!(NGCSimLib, :DocTestSetup, :(using NGCSimLib); recursive=true)

makedocs(
    modules = [NGCSimLib],
    authors = "CognitiveSubstrates AI",
    repo    = Remotes.GitHub("CognitiveSubstratesAI", "NGCSimLib"),
    sitename = "NGCSimLib",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical  = "https://cognitivesubstratesai.github.io/NGCSimLib/stable/",
        edit_link  = "main",
        assets     = String[],
    ),
    pages = [
        "Home"            => "index.md",
        "Getting Started" => "getting_started/installation.md",
        "Architecture"    => "getting_started/architecture.md",
        "Tutorials"       => Any[
            # Add tutorial pages as they're written
        ],
        "API"             => "api/index.md",
    ],
    warnonly = [:missing_docs, :cross_references],
)

deploydocs(
    repo      = "github.com/CognitiveSubstratesAI/NGCSimLib",
    devbranch = "main",
    push_preview = true,
)
