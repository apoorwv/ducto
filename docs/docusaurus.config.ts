import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const config: Config = {
  title: 'ducto',
  tagline: 'Declarative Credit Calculation Engine for AI SaaS',
  favicon: 'img/favicon.ico',

  url: 'https://apoorwv.github.io',
  baseUrl: '/ducto/',

  organizationName: 'apoorwv',
  projectName: 'ducto',

  onBrokenLinks: 'throw',
  markdown: {
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          editUrl:
            'https://github.com/apoorwv/ducto/tree/main/docs/',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    image: 'img/docusaurus-social-card.jpg',
    colorMode: {
      respectPrefersColorScheme: true,
    },
    navbar: {
      title: 'ducto',
      logo: {
        alt: 'ducto',
        src: 'img/logo.svg',
      },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'docs',
          position: 'left',
          label: 'Docs',
        },
        {
          href: 'https://github.com/apoorwv/ducto',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Docs',
          items: [
            {
              label: 'Getting Started',
              to: '/docs/intro',
            },
            {
              label: 'Python API',
              to: '/docs/python-api',
            },
            {
              label: 'JavaScript API',
              to: '/docs/javascript-api',
            },
          ],
        },
        {
          title: 'Community',
          items: [
            {
              label: 'GitHub Issues',
              href: 'https://github.com/apoorwv/ducto/issues',
            },
            {
              label: 'GitHub Discussions',
              href: 'https://github.com/apoorwv/ducto/discussions',
            },
          ],
        },
        {
          title: 'More',
          items: [
            {
              label: 'GitHub',
              href: 'https://github.com/apoorwv/ducto',
            },
            {
              label: 'PyPI',
              href: 'https://pypi.org/project/ducto/',
            },
            {
              label: 'npm',
              href: 'https://www.npmjs.com/package/@apoorwv/ducto',
            },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} ducto. MIT License.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ['python', 'bash', 'json'],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
