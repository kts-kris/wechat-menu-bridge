type Listener<T> = (event: T) => void | Promise<void>;

export class EventBus<Events extends object> {
  private readonly listeners: { [K in keyof Events]?: Set<Listener<Events[K]>> } = Object.create(null);

  subscribe<K extends keyof Events>(topic: K, listener: Listener<Events[K]>): () => void {
    const group = this.listeners[topic] ??= new Set();
    group.add(listener);
    return () => { group.delete(listener); };
  }

  async publish<K extends keyof Events>(topic: K, event: Events[K]): Promise<void> {
    const group = [...(this.listeners[topic] ?? [])];
    await Promise.allSettled(group.map(async listener => listener(event)));
  }
}
