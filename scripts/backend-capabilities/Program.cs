// Product-owned read-only bridge over the pinned, licensed Filee engine graph.
using System.Text.Json;
using Filee.Core.Conversion;
using Filee.Core.Formats;
using Filee.Core.Settings;
using Filee.Engines;
using Filee.Engines.Infrastructure;

var data = Environment.GetEnvironmentVariable("FILEE_DATA_DIR");
if (string.IsNullOrWhiteSpace(data) || !Path.IsPathFullyQualified(data))
    throw new ArgumentException("FILEE_DATA_DIR must name an isolated absolute directory");
Directory.CreateDirectory(data);
EngineEnvironment.SearchSystem = false;
var converters = EngineRegistry.CreateAll(new EngineEnvironment(data));
var catalog = new ConverterCatalog(converters);
var installed = catalog.CreatePlanner();
var optional = catalog.CreatePlanner(converters.Select(c => c.Id).ToArray());
var formats = FormatRegistry.Known;
var result = new
{
    schemaVersion = 1,
    backendVersion = typeof(EngineRegistry).Assembly.GetName().Version?.ToString(),
    engines = converters.Select(engine => new
    {
        id = engine.Id, name = engine.DisplayName,
        available = catalog.StatusOf(engine).IsAvailable,
        reason = catalog.StatusOf(engine).ReasonKey,
        detail = catalog.StatusOf(engine).Detail,
        version = catalog.StatusOf(engine).Version,
    }).ToArray(),
    formats = formats.Select(source => new
    {
        id = source.Id,
        current = formats.Where(target => target.Writable && installed.CanConvert(source.Id, target.Id)).Select(t => t.Id).ToArray(),
        optional = formats.Where(target => target.Writable && !installed.CanConvert(source.Id, target.Id) && optional.CanConvert(source.Id, target.Id)).Select(t => t.Id).ToArray(),
    }).ToArray(),
    archiveCombiner = EngineRegistry.FindFileCombiner(converters)?.CanCombineInto("zip") == true,
    pdfMerger = EngineRegistry.FindPdfMerger(converters) is not null,
};
Console.WriteLine(JsonSerializer.Serialize(result));
