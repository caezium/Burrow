using BurrowWin.Models;

namespace BurrowWin.Services;

public static class DiskTreemapLayout
{
    private const int MaxTiles = 64;
    private const double Gap = 4;

    public static IReadOnlyList<DiskTreemapRect> Build(
        DiskUsageNode root,
        double width,
        double height)
    {
        if (width <= 0 || height <= 0 || root.SizeBytes <= 0)
        {
            return Array.Empty<DiskTreemapRect>();
        }

        var source = root.Children.Count > 0 ? root.Children : [root];
        var nodes = source
            .Where(node => node.SizeBytes > 0)
            .OrderByDescending(node => node.SizeBytes)
            .Take(MaxTiles)
            .ToList();

        if (nodes.Count == 0)
        {
            return Array.Empty<DiskTreemapRect>();
        }

        var output = new List<DiskTreemapRect>();
        var colorIndex = 0;
        LayoutNodes(nodes, new LayoutRect(0, 0, width, height), 0, output, ref colorIndex);
        return output;
    }

    private static void LayoutNodes(
        IReadOnlyList<DiskUsageNode> nodes,
        LayoutRect rect,
        int depth,
        List<DiskTreemapRect> output,
        ref int colorIndex)
    {
        if (nodes.Count == 0 || rect.Width <= 1 || rect.Height <= 1)
        {
            return;
        }

        var totalSize = nodes.Sum(node => Math.Max(0, node.SizeBytes));
        if (totalSize <= 0)
        {
            return;
        }

        var areaScale = rect.Area / totalSize;
        var items = nodes
            .Select(node => new TreemapItem(node, Math.Max(1, node.SizeBytes * areaScale)))
            .OrderByDescending(item => item.Area)
            .ToList();

        Squarify(items, rect, depth, output, ref colorIndex);
    }

    private static void Squarify(
        List<TreemapItem> items,
        LayoutRect initialRect,
        int depth,
        List<DiskTreemapRect> output,
        ref int colorIndex)
    {
        var rect = initialRect;
        var row = new List<TreemapItem>();
        var remaining = new Queue<TreemapItem>(items);

        while (remaining.Count > 0)
        {
            var next = remaining.Peek();
            var side = Math.Min(rect.Width, rect.Height);
            if (row.Count == 0 || WorstAspect(row.Append(next), side) <= WorstAspect(row, side))
            {
                row.Add(remaining.Dequeue());
                continue;
            }

            rect = LayoutRow(row, rect, depth, output, ref colorIndex);
            row.Clear();
        }

        if (row.Count > 0)
        {
            LayoutRow(row, rect, depth, output, ref colorIndex);
        }
    }

    private static LayoutRect LayoutRow(
        IReadOnlyList<TreemapItem> row,
        LayoutRect rect,
        int depth,
        List<DiskTreemapRect> output,
        ref int colorIndex)
    {
        var rowArea = row.Sum(item => item.Area);
        if (rowArea <= 0)
        {
            return rect;
        }

        if (rect.Width >= rect.Height)
        {
            var rowWidth = Math.Min(rect.Width, rowArea / rect.Height);
            var y = rect.Y;
            foreach (var item in row)
            {
                var itemHeight = Math.Min(rect.Bottom - y, item.Area / rowWidth);
                AddRect(item.Node, new LayoutRect(rect.X, y, rowWidth, itemHeight), depth, output, ref colorIndex);
                y += itemHeight;
            }

            return new LayoutRect(rect.X + rowWidth, rect.Y, Math.Max(0, rect.Width - rowWidth), rect.Height);
        }

        var rowHeight = Math.Min(rect.Height, rowArea / rect.Width);
        var x = rect.X;
        foreach (var item in row)
        {
            var itemWidth = Math.Min(rect.Right - x, item.Area / rowHeight);
            AddRect(item.Node, new LayoutRect(x, rect.Y, itemWidth, rowHeight), depth, output, ref colorIndex);
            x += itemWidth;
        }

        return new LayoutRect(rect.X, rect.Y + rowHeight, rect.Width, Math.Max(0, rect.Height - rowHeight));
    }

    private static void AddRect(
        DiskUsageNode node,
        LayoutRect rect,
        int depth,
        List<DiskTreemapRect> output,
        ref int colorIndex)
    {
        var tileRect = rect.Inset(Gap);
        if (tileRect.Width < 10 || tileRect.Height < 10)
        {
            return;
        }

        output.Add(new DiskTreemapRect(
            node.Name,
            node.Path,
            node.SizeBytes,
            tileRect.X,
            tileRect.Y,
            tileRect.Width,
            tileRect.Height,
            depth,
            colorIndex++));
    }

    private static double WorstAspect(IEnumerable<TreemapItem> row, double side)
    {
        var areas = row.Select(item => item.Area).ToList();
        if (areas.Count == 0 || side <= 0)
        {
            return double.MaxValue;
        }

        var sum = areas.Sum();
        var max = areas.Max();
        var min = areas.Min();
        var sideSquared = side * side;
        var sumSquared = sum * sum;
        return Math.Max(sideSquared * max / sumSquared, sumSquared / (sideSquared * min));
    }

    private sealed record TreemapItem(DiskUsageNode Node, double Area);

    private sealed record LayoutRect(double X, double Y, double Width, double Height)
    {
        public double Right => X + Width;

        public double Bottom => Y + Height;

        public double Area => Width * Height;

        public LayoutRect Inset(double value)
        {
            var insetWidth = Math.Max(0, Width - value * 2);
            var insetHeight = Math.Max(0, Height - value * 2);
            return new LayoutRect(X + value, Y + value, insetWidth, insetHeight);
        }
    }
}
