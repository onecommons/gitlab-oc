import { something } from 'infection-pkg'; // eslint-disable-line import/no-unresolved
import type { Shape } from './shape';

export const leaf = (s: Shape): string => something(s.name as string);
