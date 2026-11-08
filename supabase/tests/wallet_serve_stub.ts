// Test stand-in for std's serve(): keeps the handler instead of opening a port.
export function serve(h: (req: Request) => Promise<Response>) {
  (globalThis as any).__handler = h;
}
