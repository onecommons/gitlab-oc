import type { Something } from 'infection-pkg'; // eslint-disable-line import/no-unresolved
import { typed } from './typed';

export const describe = (s: Something): string => typed + String(s);
