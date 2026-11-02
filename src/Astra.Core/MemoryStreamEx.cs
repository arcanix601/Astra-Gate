namespace Astra.Core;

public static class MemoryStreamEx
{
    extension(MemoryStream ms)
    {
        public Memory<byte> WrittenMemory => new(ms.GetBuffer(), 0, checked((int)ms.Length));
        public Span<byte> WrittenSpan => new(ms.GetBuffer(), 0, checked((int)ms.Length));
    }
}