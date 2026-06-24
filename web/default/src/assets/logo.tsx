/*
Copyright (C) 2023-2026 Nexus

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

For commercial licensing, please contact support@nexus.ai
*/
import { type SVGProps } from 'react'
import { cn } from '@/lib/utils'

export function Logo({ className, width = 24, height = 24 }: SVGProps<SVGSVGElement>) {
  return (
    <img
      src='/logo.png'
      alt='Nexus'
      width={width as number}
      height={height as number}
      className={cn('size-6 object-contain', className)}
    />
  )
}
