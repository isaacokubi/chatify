// Helpers for safe, retryable client message mutations.
const CLIENT_MUTATION_ID = /^[A-Za-z0-9_-]{16,100}$/;

export function validateClientMutationId(value) {
  if (value === undefined || value === null || value === '') return { value: null };
  const id = String(value).trim();
  if (!CLIENT_MUTATION_ID.test(id)) return { error: 'clientMutationId must be 16 to 100 URL-safe characters' };
  return { value: id };
}
