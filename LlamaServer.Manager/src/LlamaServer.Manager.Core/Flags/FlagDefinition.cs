namespace LlamaServer.Manager.Core.Flags;

public enum FlagValueType
{
    Bool,
    Int,
    Float,
    Enum,
    Path,
    String,
}

public sealed class FlagDefinition
{
    public required string Id { get; init; }
    public required string Flag { get; init; }
    public string? FalseFlag { get; init; }
    public string Category { get; init; } = "Misc";
    public FlagValueType ValueType { get; init; } = FlagValueType.String;
    public string? Default { get; init; }
    public string Description { get; init; } = "";
    public IReadOnlyList<string> EnumValues { get; init; } = Array.Empty<string>();
    public bool IsFromHelp { get; init; }
}

public sealed class FlagValue
{
    public required FlagDefinition Definition { get; init; }
    public string? Value { get; set; }
    public bool Enabled { get; set; }
}
