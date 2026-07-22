var builder = WebApplication.CreateBuilder(args);

string? port = Environment.GetEnvironmentVariable("PORT");
if (!string.IsNullOrWhiteSpace(port))
{
	builder.WebHost.UseUrls($"http://*:{port}");
}

var app = builder.Build();

string[] summaries =
[
	"Sunny",
	"Cloudy",
	"Windy",
	"Rainy",
	"Stormy",
	"Foggy",
	"Clear"
];

app.MapGet("/", () => Results.Ok(new
{
	service = "weather-api",
	message = "Fake weather API is running",
	endpoints = new[] { "/health", "/weather", "/weather/{city}" }
}));

app.MapGet("/health", () => Results.Ok(new
{
	status = "ok",
	timestampUtc = DateTime.UtcNow
}));

app.MapGet("/weather/{city?}", (string? city) =>
{
	string resolvedCity = string.IsNullOrWhiteSpace(city) ? "Seattle" : city.Trim();
	int seed = HashCode.Combine(resolvedCity.ToLowerInvariant(), DateTime.UtcNow.Date);
	Random random = new(seed);

	int temperatureC = random.Next(-5, 38);
	int humidity = random.Next(25, 95);
	int windKph = random.Next(0, 45);
	string condition = summaries[random.Next(summaries.Length)];

	var response = new
	{
		city = resolvedCity,
		dateUtc = DateTime.UtcNow.ToString("yyyy-MM-dd"),
		temperatureC,
		temperatureF = 32 + (int)(temperatureC / 0.5556),
		humidityPercent = humidity,
		windKph,
		condition,
		source = "fake-data"
	};

	return Results.Ok(response);
});

app.Run();
