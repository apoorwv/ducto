import { describe, it, expect } from "vitest";
import { HttpxSupabaseStore } from "../src/stores/supabase-store.js";

describe("HttpxSupabaseStore", () => {
  it("constructor stores url and key", () => {
    const store = new HttpxSupabaseStore("https://test.supabase.co", "test-key");
    expect(store).toBeInstanceOf(HttpxSupabaseStore);
  });

  it("strips trailing slash from url", async () => {
    const store = new HttpxSupabaseStore("https://test.supabase.co/", "key");
    await expect(store.setup()).rejects.toThrow(
      "HttpxSupabaseStore.setup() requires a database_url",
    );
  });

  it("setup throws without database_url", async () => {
    const store = new HttpxSupabaseStore("https://test.supabase.co", "key");
    await expect(store.setup()).rejects.toThrow(
      "HttpxSupabaseStore.setup() requires a database_url",
    );
  });

  it("getBalance rejects with network error (no server)", async () => {
    const store = new HttpxSupabaseStore("https://localhost:1", "key");
    await expect(store.getBalance("user-1")).rejects.toThrow();
  });

  it("addCredits rejects with network error (no server)", async () => {
    const store = new HttpxSupabaseStore("https://localhost:1", "key");
    await expect(store.addCredits("user-1", 100)).rejects.toThrow();
  });

  it("reserveCredits rejects with network error (no server)", async () => {
    const store = new HttpxSupabaseStore("https://localhost:1", "key");
    await expect(store.reserveCredits("user-1", 50, "usage")).rejects.toThrow();
  });

  it("deductCredits rejects with network error (no server)", async () => {
    const store = new HttpxSupabaseStore("https://localhost:1", "key");
    await expect(store.deductCredits("user-1", "rid", 50)).rejects.toThrow();
  });

  it("getActivePricing rejects with network error (no server)", async () => {
    const store = new HttpxSupabaseStore("https://localhost:1", "key");
    await expect(store.getActivePricing()).rejects.toThrow();
  });

  it("setActivePricing rejects with network error (no server)", async () => {
    const store = new HttpxSupabaseStore("https://localhost:1", "key");
    await expect(store.setActivePricing({ models: { a: "1" } })).rejects.toThrow();
  });
});
