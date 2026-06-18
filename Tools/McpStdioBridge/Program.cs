using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace BurrowWin.McpStdioBridge;

internal static class Program
{
    private const string ProtocolVersion = "2025-11-25";
    private const string DefaultEndpoint = "http://127.0.0.1:9277/mcp";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false
    };

    private static async Task<int> Main()
    {
        var endpoint = Environment.GetEnvironmentVariable("BURROWWIN_MCP_ENDPOINT");
        if (string.IsNullOrWhiteSpace(endpoint))
        {
            endpoint = ReadEndpointFromSettings() ?? DefaultEndpoint;
        }

        using var httpClient = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(120)
        };

        string? line;
        while ((line = await Console.In.ReadLineAsync().ConfigureAwait(false)) is not null)
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            line = StripByteOrderMark(line);
            var response = await HandleLineAsync(line, httpClient, endpoint).ConfigureAwait(false);
            if (response is not null)
            {
                Console.Out.WriteLine(response.ToJsonString(JsonOptions));
                Console.Out.Flush();
            }
        }

        return 0;
    }

    private static string? ReadEndpointFromSettings()
    {
        var path = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "BurrowWin",
            "settings.json");

        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            var root = JsonNode.Parse(File.ReadAllText(path))?.AsObject();
            if (root?["HttpServerEnabled"]?.GetValue<bool>() == false)
            {
                return null;
            }

            var port = root?["HttpServerPort"]?.GetValue<int>() ?? 9277;
            port = Math.Clamp(port, 1024, 65535);
            return $"http://127.0.0.1:{port}/mcp";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException)
        {
            return null;
        }
    }

    private static string StripByteOrderMark(string line)
    {
        if (line.Length > 0 && line[0] == '\uFEFF')
        {
            return line[1..];
        }

        return line.StartsWith("ï»¿", StringComparison.Ordinal) ? line[3..] : line;
    }

    private static async Task<JsonNode?> HandleLineAsync(string line, HttpClient httpClient, string endpoint)
    {
        try
        {
            var node = JsonNode.Parse(line);
            if (node is JsonArray batch)
            {
                var responses = new JsonArray();
                foreach (var item in batch)
                {
                    if (item is JsonObject message)
                    {
                        var response = await HandleMessageAsync(message, httpClient, endpoint).ConfigureAwait(false);
                        if (response is not null)
                        {
                            responses.Add(response);
                        }
                    }
                }

                return responses.Count == 0 ? null : responses;
            }

            return node is JsonObject request
                ? await HandleMessageAsync(request, httpClient, endpoint).ConfigureAwait(false)
                : Error(null, -32600, "Invalid JSON-RPC message.");
        }
        catch (JsonException ex)
        {
            return Error(null, -32700, ex.Message);
        }
    }

    private static async Task<JsonObject?> HandleMessageAsync(
        JsonObject message,
        HttpClient httpClient,
        string endpoint)
    {
        var id = message["id"]?.DeepClone();
        var method = message["method"]?.GetValue<string>();
        if (id is null)
        {
            return null;
        }

        return method switch
        {
            "initialize" => Result(id, BuildInitializeResult()),
            "ping" => Result(id, new JsonObject()),
            "tools/list" => Result(id, new JsonObject { ["tools"] = BuildToolArray() }),
            "tools/call" => await ForwardToHttpAsync(message, httpClient, endpoint, id).ConfigureAwait(false),
            _ => Error(id, -32601, $"Unsupported MCP method: {method}")
        };
    }

    private static async Task<JsonObject> ForwardToHttpAsync(
        JsonObject message,
        HttpClient httpClient,
        string endpoint,
        JsonNode id)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, endpoint)
            {
                Content = new StringContent(message.ToJsonString(JsonOptions), Encoding.UTF8, "application/json")
            };
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
            request.Headers.Add("MCP-Protocol-Version", ProtocolVersion);

            using var response = await httpClient.SendAsync(request).ConfigureAwait(false);
            var body = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                return Error(id, -32000, $"BurrowWin MCP HTTP endpoint returned {(int)response.StatusCode}: {body}");
            }

            var node = JsonNode.Parse(body);
            return node as JsonObject ?? Error(id, -32603, "BurrowWin MCP HTTP endpoint returned invalid JSON.");
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException)
        {
            return Error(id, -32000, "BurrowWin MCP HTTP endpoint is unavailable. Start BurrowWin first or set BURROWWIN_MCP_ENDPOINT.");
        }
    }

    private static JsonObject BuildInitializeResult()
    {
        return new JsonObject
        {
            ["protocolVersion"] = ProtocolVersion,
            ["capabilities"] = new JsonObject
            {
                ["tools"] = new JsonObject()
            },
            ["serverInfo"] = new JsonObject
            {
                ["name"] = "BurrowWin",
                ["version"] = "0.1.0"
            }
        };
    }

    private static JsonArray BuildToolArray()
    {
        return new JsonArray
        {
            Tool("burrow_clean", "Preview or run Mole cleanup. Defaults to dry-run unless confirm is true.", new JsonObject
            {
                ["confirm"] = Schema("boolean", "Run the cleanup instead of dry-run preview.")
            }),
            Tool("burrow_optimize", "Preview or run Mole optimize. Defaults to dry-run unless confirm is true.", new JsonObject
            {
                ["confirm"] = Schema("boolean", "Run the optimization instead of dry-run preview.")
            }),
            Tool("burrow_snapshot", "Return current Windows telemetry used by the Dashboard fallback.", new JsonObject()),
            Tool("burrow_history", "Return recent Windows telemetry snapshots recorded by BurrowWin.", new JsonObject
            {
                ["limit"] = Schema("integer", "Maximum snapshots to return.")
            }),
            Tool("burrow_top_processes", "Return process CPU or memory leaders from recent telemetry history.", new JsonObject
            {
                ["metric"] = Schema("string", "Metric used for ranking: peak_cpu, avg_cpu, cpu_time, peak_mem, or avg_mem."),
                ["limit"] = Schema("integer", "Maximum processes to return."),
                ["history_limit"] = Schema("integer", "Maximum telemetry snapshots to scan.")
            }),
            Tool("burrow_process_usage", "Rank process usage over recent telemetry history by CPU or memory.", new JsonObject
            {
                ["metric"] = Schema("string", "Requested metric, such as peak_mem, avg_mem, peak_cpu, avg_cpu, or cpu_time."),
                ["limit"] = Schema("integer", "Maximum processes to return."),
                ["history_limit"] = Schema("integer", "Maximum telemetry snapshots to scan.")
            }),
            Tool("burrow_info", "Return what BurrowWin is recording and where local MCP/HTTP state is stored.", new JsonObject()),
            Tool("burrow_engine", "Return Mole engine availability for BurrowWin.", new JsonObject()),
            Tool("burrow_analyze", "Analyze a directory and return a size-ranked tree.", new JsonObject
            {
                ["path"] = Schema("string", "Directory path to analyze."),
                ["max_depth"] = Schema("integer", "Maximum recursive depth."),
                ["max_children"] = Schema("integer", "Maximum children per directory.")
            }),
            Tool("burrow_uninstall", "List apps, preview leftovers, or launch a confirmed vendor uninstaller.", new JsonObject
            {
                ["action"] = Schema("string", "One of list, preview_leftovers, or launch_uninstaller."),
                ["app_id"] = Schema("string", "Installed application ID returned by the list action."),
                ["search"] = Schema("string", "Optional search text for the list action."),
                ["limit"] = Schema("integer", "Maximum applications to return for the list action."),
                ["confirm"] = Schema("boolean", "Required for launch_uninstaller.")
            })
        };
    }

    private static JsonObject Tool(string name, string description, JsonObject properties)
    {
        return new JsonObject
        {
            ["name"] = name,
            ["description"] = description,
            ["inputSchema"] = new JsonObject
            {
                ["type"] = "object",
                ["properties"] = properties
            }
        };
    }

    private static JsonObject Schema(string type, string description)
    {
        return new JsonObject
        {
            ["type"] = type,
            ["description"] = description
        };
    }

    private static JsonObject Result(JsonNode id, JsonObject result)
    {
        return new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["id"] = id.DeepClone(),
            ["result"] = result
        };
    }

    private static JsonObject Error(JsonNode? id, int code, string message)
    {
        return new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["id"] = id?.DeepClone(),
            ["error"] = new JsonObject
            {
                ["code"] = code,
                ["message"] = message
            }
        };
    }
}
